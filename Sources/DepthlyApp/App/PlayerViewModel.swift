import AppKit
import AVFoundation
import CoreImage
import Foundation
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    private struct RenderResult: @unchecked Sendable {
        let image: CGImage?
        let mask: CIImage?
        let frameBuffer: CVPixelBuffer
    }

    @Published var player: AVPlayer = AVPlayer()
    @Published var overlayImage: CGImage?
    @Published var isEffectEnabled = true
    @Published var effectSettings = EffectSettings.default
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 1
    @Published var isPlaying = false
    @Published var statusText: String = "Open a local video to begin."
    @Published var videoSize: CGSize = .zero
    @Published private(set) var overlayRevision: Int = 0
    @Published var availableForegroundModels: [DepthModelOption] = []
    @Published var selectedForegroundModelID: String = DepthModelOption.visionPersonSegmentation.id
    @Published var foregroundModelStatus: String = "Vision Person Segmentation"
    @Published var isLoadingForegroundModel = false
    @Published private(set) var isForegroundModelReady = false
    @Published var isBufferingDepth = false
    @Published var bufferProgress: Double = 0
    @Published var bufferStatus: String = "Buffer not prepared"
    @Published var isBufferedDepthReady = false

    private let frameProvider = VideoFrameProvider()
    private let renderer = SplitDepthRenderer()
    private let outputRouting = PlaybackOutputRouting()
    private var foregroundMaskEstimator: any ForegroundMaskEstimating = VisionForegroundMaskEstimator()
    private var currentFrameBuffer: CVPixelBuffer?
    private var currentVideoURL: URL?
    private var isProcessingFrame = false
    private var modelLoadTask: Task<Void, Never>?
    private var bufferTask: Task<Void, Never>?
    private var didLoadDepthModelOnce = false
    private var depthModelLoadGeneration: Int = 0
    private var timeObserverToken: Any?
    private var lastDepthMap: CIImage?
    private let defaultBufferedSampleInterval: TimeInterval = 1.0 / 15.0
    private var bufferedDepthSamples: [BufferedForegroundSample] = []
    private var loadedForegroundModelID: String?
    private var pendingAutoBuffer = false

    init(foregroundMaskEstimator: (any ForegroundMaskEstimating)? = nil) {
        availableForegroundModels = DepthModelCatalog.discoverModels()
        let preferredModelID = UserDefaults.standard.string(forKey: Self.selectedForegroundModelDefaultsKey)
            ?? DepthModelOption.visionPersonSegmentation.id
        if availableForegroundModels.contains(where: { $0.id == preferredModelID }) {
            selectedForegroundModelID = preferredModelID
        } else {
            selectedForegroundModelID = DepthModelOption.visionPersonSegmentation.id
        }

        if let foregroundMaskEstimator {
            self.foregroundMaskEstimator = foregroundMaskEstimator
            selectedForegroundModelID = DepthModelOption.mock.id
            foregroundModelStatus = "Injected foreground mask"
            isForegroundModelReady = true
            loadedForegroundModelID = DepthModelOption.mock.id
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
            await self?.loadForegroundModelIfNeeded(force: true)
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
        pendingAutoBuffer = true

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.pause()
        isPlaying = false

        frameProvider.attach(to: item)
        frameProvider.start()

        installTimeObserver()
        statusText = "Preparing \(url.lastPathComponent)..."
        scheduleDepthPreparationIfPossible()

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

        guard canPrepareDepthBufferNow else {
            pendingAutoBuffer = true
            if isLoadingForegroundModel {
                statusText = "Loading foreground model before buffering..."
                bufferStatus = "Waiting for foreground model"
            } else if !isForegroundModelReady {
                statusText = "Foreground model is not ready."
                bufferStatus = "Foreground model not ready"
            } else {
                statusText = "Foreground buffer is not available yet."
            }
            return
        }

        bufferTask?.cancel()
        player.pause()
        isPlaying = false
        isBufferingDepth = true
        pendingAutoBuffer = false
        bufferProgress = 0
        bufferStatus = "Preparing depth buffer..."
        isBufferedDepthReady = false
        bufferedDepthSamples.removeAll()
        statusText = "Buffering foreground mask with \(foregroundModelDisplayName)..."

        let estimator = foregroundMaskEstimator
        let defaultSampleInterval = defaultBufferedSampleInterval
        let selectedKind = availableForegroundModels.first(where: { $0.id == selectedForegroundModelID })?.kind ?? .mock

        bufferTask = Task.detached(priority: .utility) { [videoURL, estimator, defaultSampleInterval, selectedKind] in
            do {
                let asset = AVURLAsset(url: videoURL)
                let duration = try await asset.load(.duration)
                let durationSeconds = duration.seconds.isFinite ? max(duration.seconds, 0) : 0
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    throw NSError(domain: "Depthly.Buffer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
                }

                let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
                let sampleInterval = Self.bufferedSamplingInterval(
                    nominalFrameRate: Double(nominalFrameRate),
                    kind: selectedKind,
                    fallback: defaultSampleInterval
                )
                let sampleEveryFrame = sampleInterval <= 0

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

                var buffered: [BufferedForegroundSample] = []
                var nextCaptureTime: Double = 0
                var lastPublishedProgress: Double = 0

                while reader.status == .reading && !Task.isCancelled {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

                    let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let seconds = sampleTime.seconds
                    guard seconds.isFinite else { continue }
                    if !sampleEveryFrame {
                        guard seconds + 0.0001 >= nextCaptureTime else { continue }
                        nextCaptureTime = seconds + sampleInterval
                    }

                    if let mask = try? await estimator.estimateForegroundMask(for: imageBuffer) {
                        buffered.append(BufferedForegroundSample(time: sampleTime, mask: mask))
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
                    self.bufferStatus = buffered.isEmpty ? "Buffering finished, no masks" : "Foreground buffer ready"
                    self.statusText = buffered.isEmpty ? "Buffering finished, no foreground masks" : "Foreground buffer prepared. Playback ready."
                }
            } catch {
                await MainActor.run {
                    self.isBufferingDepth = false
                    self.bufferStatus = "Buffering failed"
                    self.statusText = "Foreground buffer error: \(error.localizedDescription)"
                }
            }
        }
    }

    func togglePlayPause() {
        guard canStartPlayback else { return }

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

    func selectForegroundModel(id: String) {
        selectedForegroundModelID = id
        UserDefaults.standard.set(id, forKey: Self.selectedForegroundModelDefaultsKey)
        invalidateDepthBuffer(status: "Buffer invalidated by model change")
        pendingAutoBuffer = currentVideoURL != nil
        Task { [weak self] in
            await self?.loadForegroundModelIfNeeded(force: true)
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
        let modelName = foregroundModelStatus
        let bufferName = isBufferedDepthReady ? "buffer ready" : (isBufferingDepth ? "buffering" : "buffer missing")
        return "Foreground Mask · \(modelName) · \(bufferName)"
    }

    var canStartPlayback: Bool {
        guard currentVideoURL != nil else { return false }
        guard !isLoadingForegroundModel, !isBufferingDepth else { return false }
        return !isEffectEnabled || (isForegroundModelReady && isBufferedDepthReady)
    }

    var playbackLockReason: String {
        if isLoadingForegroundModel {
            return "Loading foreground model..."
        }
        if isBufferingDepth {
            return "Building foreground buffer..."
        }
        if isEffectEnabled && !isForegroundModelReady {
            return "Foreground model is not ready."
        }
        if isEffectEnabled && !isBufferedDepthReady {
            return "Foreground buffer is not ready."
        }
        return "Playback ready."
    }

    private func consume(frame sample: VideoFrameProvider.FrameSample) async {
        currentTime = sample.time.seconds.isFinite ? sample.time.seconds : currentTime

        guard isEffectEnabled else {
            currentFrameBuffer = sample.pixelBuffer
            overlayImage = nil
            return
        }

        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        let frameCopy = sample.pixelBuffer
        let settings = effectSettings
        let renderer = renderer
        let cachedMask = lastDepthMap
        let bufferedMask = isBufferedDepthReady ? bufferedForegroundMask(near: sample.time) : nil

        let result = await Task.detached(priority: .userInitiated) {
            var mask = cachedMask
            if let bufferedMask {
                mask = bufferedMask
            }

            let image = renderer.renderOverlay(frame: frameCopy, foregroundMask: mask, settings: settings)
            return RenderResult(image: image, mask: mask, frameBuffer: frameCopy)
        }.value

        overlayImage = result.image
        lastDepthMap = result.mask
        currentFrameBuffer = result.frameBuffer
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
        renderer.reset()
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

    private func bufferedForegroundMask(near time: CMTime) -> CIImage? {
        guard !bufferedDepthSamples.isEmpty else { return nil }

        let targetSeconds = time.seconds
        guard targetSeconds.isFinite else { return bufferedDepthSamples.first?.mask }

        var bestSample: BufferedForegroundSample?
        var bestDistance = Double.greatestFiniteMagnitude

        for sample in bufferedDepthSamples {
            let distance = abs(sample.time.seconds - targetSeconds)
            if distance < bestDistance {
                bestDistance = distance
                bestSample = sample
            }
        }

        return bestSample?.mask
    }

    private func loadForegroundModelIfNeeded(force: Bool = false) async {
        modelLoadTask?.cancel()
        depthModelLoadGeneration &+= 1
        let generation = depthModelLoadGeneration

        let selected = availableForegroundModels.first(where: { $0.id == selectedForegroundModelID }) ?? .visionPersonSegmentation
        if !force, didLoadDepthModelOnce, selected.id == selectedForegroundModelID {
            return
        }

        if selected.isMock {
            foregroundMaskEstimator = MockForegroundMaskEstimator()
            foregroundModelStatus = selected.displayName
            isLoadingForegroundModel = false
            isForegroundModelReady = true
            loadedForegroundModelID = selected.id
            didLoadDepthModelOnce = true
            scheduleDepthPreparationIfPossible()
            return
        }

        if selected.isBuiltInVision {
            foregroundMaskEstimator = VisionForegroundMaskEstimator()
            foregroundModelStatus = selected.displayName
            isLoadingForegroundModel = false
            isForegroundModelReady = true
            loadedForegroundModelID = selected.id
            effectSettings.invertDepthMask = false
            didLoadDepthModelOnce = true
            scheduleDepthPreparationIfPossible()
            return
        }

        guard let fileURL = selected.fileURL else {
            foregroundMaskEstimator = MockForegroundMaskEstimator()
            foregroundModelStatus = "Missing model source"
            isLoadingForegroundModel = false
            isForegroundModelReady = false
            loadedForegroundModelID = nil
            pendingAutoBuffer = false
            bufferStatus = "Model source missing"
            statusText = "Foreground model source is unavailable."
            didLoadDepthModelOnce = true
            return
        }

        isLoadingForegroundModel = true
        isForegroundModelReady = false
        loadedForegroundModelID = nil
        foregroundModelStatus = "Loading \(selected.displayName)..."
        if currentVideoURL != nil {
            statusText = "Loading \(selected.displayName)..."
            bufferStatus = "Waiting for foreground model"
        }

        modelLoadTask = Task.detached(priority: .userInitiated) { [fileURL, displayName = selected.displayName, generation] in
            do {
                let estimator = try await CoreMLForegroundMaskEstimator(modelURL: fileURL)
                await MainActor.run {
                    guard self.depthModelLoadGeneration == generation else { return }
                    self.foregroundMaskEstimator = estimator
                    self.foregroundModelStatus = "Core ML · \(displayName)"
                    self.isLoadingForegroundModel = false
                    self.isForegroundModelReady = true
                    self.loadedForegroundModelID = self.selectedForegroundModelID
                    self.effectSettings.invertDepthMask = false
                    self.didLoadDepthModelOnce = true
                    self.scheduleDepthPreparationIfPossible()
                }
            } catch {
                await MainActor.run {
                    guard self.depthModelLoadGeneration == generation else { return }
                    self.foregroundMaskEstimator = MockForegroundMaskEstimator()
                    self.foregroundModelStatus = "Failed to load \(displayName)"
                    self.isLoadingForegroundModel = false
                    self.isForegroundModelReady = false
                    self.loadedForegroundModelID = nil
                    self.pendingAutoBuffer = false
                    self.bufferStatus = "Model load failed"
                    self.statusText = "Foreground model load error: \(error.localizedDescription)"
                    self.didLoadDepthModelOnce = true
                }
            }
        }
    }

    private var canPrepareDepthBufferNow: Bool {
        guard currentVideoURL != nil else { return false }
        guard !isLoadingForegroundModel else { return false }
        guard isForegroundModelReady else { return false }
        guard loadedForegroundModelID == selectedForegroundModelID else { return false }
        return true
    }

    private var foregroundModelDisplayName: String {
        availableForegroundModels.first(where: { $0.id == selectedForegroundModelID })?.displayName ?? foregroundModelStatus
    }

    private func scheduleDepthPreparationIfPossible() {
        guard currentVideoURL != nil else { return }
        guard pendingAutoBuffer else { return }

        if canPrepareDepthBufferNow {
            prepareDepthBuffer()
            return
        }

        if isLoadingForegroundModel {
            statusText = "Loading foreground model before buffering..."
            bufferStatus = "Waiting for foreground model"
        } else if !isForegroundModelReady {
            statusText = "Foreground model is not ready."
            bufferStatus = "Foreground model not ready"
        }
    }

    nonisolated private static func bufferedSamplingInterval(
        nominalFrameRate nominalFPS: Double,
        kind: DepthModelOption.Kind,
        fallback: TimeInterval
    ) -> TimeInterval {
        if kind == .visionPersonSegmentation {
            return 0
        }

        guard nominalFPS.isFinite, nominalFPS > 0 else { return fallback }

        let targetFPS = min(max(nominalFPS, 12.0), 24.0)
        return 1.0 / targetFPS
    }

    private static let selectedForegroundModelDefaultsKey = "selectedForegroundModelID"
}

private struct BufferedForegroundSample: @unchecked Sendable {
    let time: CMTime
    let mask: CIImage
}
