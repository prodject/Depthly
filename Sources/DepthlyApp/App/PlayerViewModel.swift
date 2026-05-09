import AppKit
import AVFoundation
import CoreImage
import Foundation
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    enum ProcessingMode: String, CaseIterable, Identifiable, Sendable {
        case live = "Live"
        case auto = "Auto"
        case buffered = "Buffered"

        var id: String { rawValue }
    }

    @Published var player: AVPlayer = AVPlayer()
    @Published var overlayImage: CGImage?
    @Published var isEffectEnabled = true
    @Published var effectSettings = EffectSettings.default
    @Published var processingMode: ProcessingMode = .auto
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 1
    @Published var isPlaying = false
    @Published var statusText: String = "Open a local video to begin."
    @Published var videoSize: CGSize = .zero
    @Published private(set) var overlayRevision: Int = 0
    @Published var availableDepthModels: [DepthModelOption] = []
    @Published var selectedDepthModelID: String = DepthModelOption.mock.id
    @Published var depthModelStatus: String = "Mock depth"
    @Published var isLoadingDepthModel = false
    @Published var isBufferingDepth = false
    @Published var bufferProgress: Double = 0
    @Published var bufferStatus: String = "Buffer not prepared"
    @Published var isBufferedDepthReady = false

    private let frameProvider = VideoFrameProvider()
    private let renderer = SplitDepthRenderer()
    private let outputRouting = PlaybackOutputRouting()
    private var depthEstimator: any DepthEstimating = MockDepthEstimator()
    private var currentFrameBuffer: CVPixelBuffer?
    private var currentVideoURL: URL?
    private var isProcessingFrame = false
    private var modelLoadTask: Task<Void, Never>?
    private var bufferTask: Task<Void, Never>?
    private var didLoadDepthModelOnce = false
    private var depthModelLoadGeneration: Int = 0
    private var timeObserverToken: Any?
    private var lastDepthMap: CIImage?
    private var lastInferenceDate: Date = .distantPast
    private let inferenceInterval: TimeInterval = 0.12
    private let bufferedSampleInterval: TimeInterval = 0.25
    private var bufferedDepthSamples: [BufferedDepthSample] = []

    init(depthEstimator: (any DepthEstimating)? = nil) {
        availableDepthModels = DepthModelCatalog.discoverModels()
        selectedDepthModelID = UserDefaults.standard.string(forKey: Self.selectedDepthModelDefaultsKey)
            ?? availableDepthModels.first(where: { !$0.isMock })?.id
            ?? DepthModelOption.mock.id

        if let depthEstimator {
            self.depthEstimator = depthEstimator
            selectedDepthModelID = DepthModelOption.mock.id
            depthModelStatus = "Injected estimator"
        }

        frameProvider.onFrameAvailable = { [weak self] sample in
            Task { [weak self] in
                await self?.consume(frame: sample)
            }
        }

        player.volume = Float(volume)
        player.automaticallyWaitsToMinimizeStalling = true
        outputRouting.attach(to: player)

        Task { [weak self] in
            await self?.loadDepthModelIfNeeded(force: true)
        }
    }

    func openVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url: url)
    }

    func loadVideo(url: URL) {
        stopFramePipeline()
        invalidateDepthBuffer(status: "Buffer not prepared")
        currentVideoURL = url

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.playImmediately(atRate: 1.0)
        isPlaying = true

        frameProvider.attach(to: item)
        frameProvider.start()

        installTimeObserver()
        statusText = url.lastPathComponent

        Task {
            do {
                let loadedDuration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                await MainActor.run {
                    self.duration = loadedDuration.seconds.isFinite ? loadedDuration.seconds : 0
                }

                if let videoTrack = tracks.first {
                    let naturalSize = try await videoTrack.load(.naturalSize)
                    let preferredTransform = try await videoTrack.load(.preferredTransform)
                    let transformedSize = naturalSize.applying(preferredTransform)
                    await MainActor.run {
                        self.videoSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusText = "Failed to read asset metadata: \(error.localizedDescription)"
                }
            }
        }
    }

    func prepareDepthBuffer() {
        guard let videoURL = currentVideoURL else {
            statusText = "Open a video first."
            return
        }

        bufferTask?.cancel()
        player.pause()
        isPlaying = false
        isBufferingDepth = true
        bufferProgress = 0
        bufferStatus = "Preparing depth buffer..."
        isBufferedDepthReady = false
        bufferedDepthSamples.removeAll()

        let estimator = depthEstimator
        let sampleInterval = bufferedSampleInterval

        bufferTask = Task.detached(priority: .utility) { [videoURL, estimator, sampleInterval] in
            do {
                let asset = AVURLAsset(url: videoURL)
                let duration = try await asset.load(.duration)
                let durationSeconds = duration.seconds.isFinite ? max(duration.seconds, 0) : 0
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    throw NSError(domain: "Depthly.Buffer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
                }

                let reader = try AVAssetReader(asset: asset)
                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                output.alwaysCopiesSampleData = false
                if reader.canAdd(output) {
                    reader.add(output)
                } else {
                    throw NSError(domain: "Depthly.Buffer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to attach reader output"])
                }

                guard reader.startReading() else {
                    throw reader.error ?? NSError(domain: "Depthly.Buffer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to start asset reader"])
                }

                var buffered: [BufferedDepthSample] = []
                var nextCaptureTime: Double = 0
                var lastPublishedProgress: Double = 0

                while reader.status == .reading && !Task.isCancelled {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

                    let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let seconds = sampleTime.seconds
                    guard seconds.isFinite else { continue }
                    guard seconds + 0.0001 >= nextCaptureTime else { continue }

                    nextCaptureTime = seconds + sampleInterval

                    if let depthMap = try? await estimator.estimateDepthMap(for: imageBuffer) {
                        buffered.append(BufferedDepthSample(time: sampleTime, depthMap: depthMap))
                    }

                    let progress = durationSeconds > 0 ? min(1, seconds / durationSeconds) : 0
                    if progress - lastPublishedProgress >= 0.04 || progress >= 1.0 {
                        lastPublishedProgress = progress
                        await MainActor.run {
                            self.bufferProgress = progress
                            self.bufferStatus = "Preparing depth buffer... \(Int(progress * 100))%"
                        }
                    }
                }

                if Task.isCancelled {
                    await MainActor.run {
                        self.isBufferingDepth = false
                        self.bufferStatus = "Buffering cancelled"
                    }
                    return
                }

                await MainActor.run {
                    self.bufferedDepthSamples = buffered.sorted { $0.time.seconds < $1.time.seconds }
                    self.isBufferedDepthReady = !buffered.isEmpty
                    self.isBufferingDepth = false
                    self.bufferProgress = 1
                    self.bufferStatus = buffered.isEmpty ? "Buffering finished, no samples" : "Depth buffer ready"
                    self.statusText = buffered.isEmpty ? "Buffering finished, no depth samples" : "Depth buffer prepared"
                }
            } catch {
                await MainActor.run {
                    self.isBufferingDepth = false
                    self.bufferStatus = "Buffering failed"
                    self.statusText = "Buffer error: \(error.localizedDescription)"
                }
            }
        }
    }

    func togglePlayPause() {
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to normalizedProgress: Double) {
        guard duration > 0 else { return }
        let clamped = max(0, min(1, normalizedProgress))
        let seconds = duration * clamped
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(1, value))
        player.volume = Float(volume)
    }

    func selectDepthModel(id: String) {
        selectedDepthModelID = id
        UserDefaults.standard.set(id, forKey: Self.selectedDepthModelDefaultsKey)
        invalidateDepthBuffer(status: "Buffer invalidated by model change")
        Task { [weak self] in
            await self?.loadDepthModelIfNeeded(force: true)
        }
    }

    func setProcessingMode(_ mode: ProcessingMode) {
        processingMode = mode
        if mode == .live {
            bufferStatus = "Live mode selected"
        } else if mode == .buffered {
            bufferStatus = isBufferedDepthReady ? "Buffered playback ready" : "Buffered mode selected"
        } else {
            bufferStatus = isBufferedDepthReady ? "Auto mode using buffer" : "Auto mode using live inference"
        }
    }

    func bindingProgress() -> Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    func metalRenderState() -> MetalSplitDepthRenderState {
        MetalSplitDepthRenderState(
            frameBuffer: currentFrameBuffer,
            overlayImage: overlayImage,
            videoSize: videoSize,
            borderThickness: effectSettings.borderThickness,
            isEffectEnabled: isEffectEnabled,
            overlayRevision: overlayRevision
        )
    }

    var activeProcessingStatusText: String {
        let mode: String
        switch processingMode {
        case .live:
            mode = "Live"
        case .auto:
            mode = isBufferedDepthReady ? "Auto (buffered)" : "Auto (live)"
        case .buffered:
            mode = "Buffered"
        }

        let modelName = depthModelStatus
        let bufferName: String
        switch processingMode {
        case .live:
            bufferName = "buffer bypassed"
        case .auto:
            bufferName = isBufferedDepthReady ? "buffer ready" : "no buffer"
        case .buffered:
            bufferName = isBufferedDepthReady ? "buffer active" : "buffer missing"
        }

        return "\(mode) · \(modelName) · \(bufferName)"
    }

    private func consume(frame sample: VideoFrameProvider.FrameSample) async {
        currentTime = sample.time.seconds.isFinite ? sample.time.seconds : currentTime
        currentFrameBuffer = sample.pixelBuffer

        guard isEffectEnabled else {
            overlayImage = nil
            return
        }

        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        let frameCopy = sample.pixelBuffer
        let settings = effectSettings
        let depthEstimator = depthEstimator
        let renderer = renderer
        let cachedDepth = lastDepthMap
        let bufferedDepth: CIImage?
        switch processingMode {
        case .live:
            bufferedDepth = nil
        case .auto, .buffered:
            bufferedDepth = isBufferedDepthReady ? bufferedDepthMap(near: sample.time) : nil
        }
        let shouldRefreshDepth = bufferedDepth == nil && Date().timeIntervalSince(lastInferenceDate) >= inferenceInterval

        let result = await Task.detached(priority: .userInitiated) {
            var depth = cachedDepth
            if let bufferedDepth {
                depth = bufferedDepth
            } else if shouldRefreshDepth {
                depth = try? await depthEstimator.estimateDepthMap(for: frameCopy)
            }

            let image = renderer.renderOverlay(frame: frameCopy, depthMap: depth, settings: settings)
            return (image, depth)
        }.value

        overlayImage = result.0
        lastDepthMap = result.1
        lastInferenceDate = .now
        overlayRevision &+= 1
        isProcessingFrame = false
    }

    private func installTimeObserver() {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : self.currentTime
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    private func stopFramePipeline() {
        frameProvider.stop()
        overlayImage = nil
        lastDepthMap = nil
        isProcessingFrame = false
        isPlaying = false
        currentFrameBuffer = nil
        bufferTask?.cancel()
        bufferTask = nil
    }

    private func invalidateDepthBuffer(status: String) {
        bufferTask?.cancel()
        bufferTask = nil
        bufferedDepthSamples.removeAll()
        isBufferedDepthReady = false
        isBufferingDepth = false
        bufferProgress = 0
        bufferStatus = status
    }

    private func bufferedDepthMap(near time: CMTime) -> CIImage? {
        guard !bufferedDepthSamples.isEmpty else { return nil }

        let targetSeconds = time.seconds
        guard targetSeconds.isFinite else { return bufferedDepthSamples.first?.depthMap }

        var bestSample: BufferedDepthSample?
        var bestDistance = Double.greatestFiniteMagnitude

        for sample in bufferedDepthSamples {
            let distance = abs(sample.time.seconds - targetSeconds)
            if distance < bestDistance {
                bestDistance = distance
                bestSample = sample
            }
        }

        return bestSample?.depthMap
    }

    private func loadDepthModelIfNeeded(force: Bool = false) async {
        modelLoadTask?.cancel()
        depthModelLoadGeneration &+= 1
        let generation = depthModelLoadGeneration

        let selected = availableDepthModels.first(where: { $0.id == selectedDepthModelID }) ?? .mock
        if !force, didLoadDepthModelOnce, selected.id == selectedDepthModelID {
            return
        }

        guard !selected.isMock, let fileURL = selected.fileURL else {
            depthEstimator = MockDepthEstimator()
            depthModelStatus = selected.displayName
            isLoadingDepthModel = false
            didLoadDepthModelOnce = true
            return
        }

        isLoadingDepthModel = true
        depthModelStatus = "Loading \(selected.displayName)..."

        modelLoadTask = Task.detached(priority: .userInitiated) { [fileURL, displayName = selected.displayName, generation] in
            do {
                let estimator = try await CoreMLDepthEstimator(modelURL: fileURL)
                await MainActor.run {
                    guard self.depthModelLoadGeneration == generation else { return }
                    self.depthEstimator = estimator
                    self.depthModelStatus = "Core ML · \(displayName)"
                    self.isLoadingDepthModel = false
                    self.didLoadDepthModelOnce = true
                }
            } catch {
                await MainActor.run {
                    guard self.depthModelLoadGeneration == generation else { return }
                    self.depthEstimator = MockDepthEstimator()
                    self.depthModelStatus = "Failed to load \(displayName)"
                    self.statusText = "Model load error: \(error.localizedDescription)"
                    self.isLoadingDepthModel = false
                    self.didLoadDepthModelOnce = true
                }
            }
        }
    }

    private static let selectedDepthModelDefaultsKey = "selectedDepthModelID"
}

private struct BufferedDepthSample: @unchecked Sendable {
    let time: CMTime
    let depthMap: CIImage
}
