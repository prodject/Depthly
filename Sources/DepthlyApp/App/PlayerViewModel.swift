import AppKit
import AVFoundation
import CoreImage
import Foundation
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
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

    private let frameProvider = VideoFrameProvider()
    private let renderer = SplitDepthRenderer()
    private let outputRouting = PlaybackOutputRouting()
    private let depthEstimator: any DepthEstimating
    private var isProcessingFrame = false
    private var timeObserverToken: Any?
    private var lastDepthMap: CIImage?
    private var lastInferenceDate: Date = .distantPast
    private let inferenceInterval: TimeInterval = 0.12

    init(depthEstimator: (any DepthEstimating)? = nil) {
        if let depthEstimator {
            self.depthEstimator = depthEstimator
        } else {
            self.depthEstimator = PlayerViewModel.makeDefaultDepthEstimator()
        }

        frameProvider.onFrameAvailable = { [weak self] sample in
            Task { [weak self] in
                await self?.consume(frame: sample)
            }
        }

        player.volume = Float(volume)
        player.automaticallyWaitsToMinimizeStalling = true
        outputRouting.attach(to: player)
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

    func bindingProgress() -> Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    private func consume(frame sample: VideoFrameProvider.FrameSample) async {
        currentTime = sample.time.seconds.isFinite ? sample.time.seconds : currentTime

        guard isEffectEnabled else {
            overlayImage = nil
            return
        }

        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        let shouldRefreshDepth = Date().timeIntervalSince(lastInferenceDate) >= inferenceInterval
        let frameCopy = sample.pixelBuffer
        let settings = effectSettings
        let depthEstimator = depthEstimator
        let renderer = renderer
        let cachedDepth = lastDepthMap

        let result = await Task.detached(priority: .userInitiated) {
            var depth = cachedDepth
            if shouldRefreshDepth {
                depth = try? await depthEstimator.estimateDepthMap(for: frameCopy)
            }

            let image = renderer.renderOverlay(frame: frameCopy, depthMap: depth, settings: settings)
            return (image, depth)
        }.value

        overlayImage = result.0
        lastDepthMap = result.1
        lastInferenceDate = .now
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
    }

    private static func makeDefaultDepthEstimator() -> any DepthEstimating {
        if let url = Bundle.main.url(forResource: "DepthAnythingV2Small", withExtension: "mlmodelc"),
           let estimator = try? CoreMLDepthEstimator(compiledModelURL: url) {
            return estimator
        }
        return MockDepthEstimator()
    }
}
