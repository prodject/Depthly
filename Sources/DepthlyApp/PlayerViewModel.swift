import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreMedia
import Foundation
import UniformTypeIdentifiers

private let prebufferImageContext = CIContext(options: nil)

@MainActor
final class PlayerViewModel: ObservableObject, PlayerOverlayProviding {
    @Published var overlayImage: NSImage?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false
    @Published var volume: Double = 1.0
    @Published var effectSettings: EffectSettings = .default
    @Published var isBuffering: Bool = false
    @Published var bufferProgress: Double = 0
    @Published var statusMessage: String = "Open a local video to begin."

    let player = AVPlayer()

    private let frameProvider = AVPlayerItemFrameProvider()
    private let depthEstimator: DepthEstimating = AdaptiveDepthEstimator()
    private let foregroundMaskProvider: ForegroundMaskProviding = AdaptiveForegroundMaskProvider()
    private let maskFusion = MaskFusion()
    private let temporalSmoother = TemporalMaskSmoother()
    private let maskCache = MaskCache()
    private let renderer = SplitDepthRenderer()
    private let airPlayCoordinator = AirPlayCoordinator()

    private var renderTimer: DispatchSourceTimer?
    private let renderQueue = DispatchQueue(label: "Depthly.render.queue", qos: .userInitiated)
    private var observationTokens: [NSKeyValueObservation] = []
    private var currentVideoURL: URL?
    private var bufferTask: Task<Void, Never>?

    init() {
        airPlayCoordinator.configure(player: player)
        volume = Double(player.volume)
        startRenderLoop()
        observePlayerState()
    }

    deinit {
        renderTimer?.cancel()
        frameProvider.detach()
        bufferTask?.cancel()
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        let asset = AVAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        currentVideoURL = url
        frameProvider.detach()
        frameProvider.attach(to: item)
        temporalSmoother.reset()
        maskCache.removeAll()

        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        player.play()

        statusMessage = url.lastPathComponent
        refreshDuration()
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let clamped = max(0.0, min(1.0, fraction))
        let target = CMTime(seconds: duration * clamped, preferredTimescale: 600)
        temporalSmoother.reset()
        maskCache.removeAll()
        player.seek(to: target)
    }

    func updateVolume(_ newValue: Double) {
        volume = max(0.0, min(1.0, newValue))
        player.volume = Float(volume)
    }

    func setEffectEnabled(_ enabled: Bool) {
        effectSettings.isEnabled = enabled
        if !enabled {
            overlayImage = nil
            temporalSmoother.reset()
        }
    }

    func setMaskMode(_ mode: MaskPipelineMode) {
        effectSettings.maskMode = mode
        temporalSmoother.reset()
        maskCache.removeAll()
    }

    func bufferPlayback() {
        guard !isBuffering, let url = currentVideoURL, duration > 0 else {
            return
        }

        let shouldResume = isPlaying
        player.pause()
        isBuffering = true
        bufferProgress = 0
        statusMessage = "Buffering masks..."

        bufferTask?.cancel()
        let settingsSnapshot = effectSettings
        let startTime = player.currentTime()

        bufferTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.prebufferMasks(
                    videoURL: url,
                    startTime: startTime,
                    settings: settingsSnapshot
                )

                await MainActor.run {
                    self.isBuffering = false
                    self.bufferProgress = 1.0
                    self.statusMessage = "Buffer ready"
                    if shouldResume {
                        self.player.play()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isBuffering = false
                    self.statusMessage = "Buffering failed: \(error.localizedDescription)"
                    if shouldResume {
                        self.player.play()
                    }
                }
            }
        }
    }

    private func startRenderLoop() {
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 24.0, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.renderTick()
        }
        timer.resume()
        renderTimer = timer
    }

    private func renderTick() {
        guard effectSettings.isEnabled, !isBuffering, let item = player.currentItem else {
            return
        }

        let playerTime = player.currentTime()
        guard let (pixelBuffer, itemTime) = frameProvider.copyCurrentPixelBuffer(at: playerTime) else {
            return
        }

        let shouldAnalyzeThisFrame = itemTime.seconds.isFinite
        guard shouldAnalyzeThisFrame else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.processFrame(pixelBuffer: pixelBuffer, timestamp: itemTime, duration: item.duration.seconds)
        }
    }

    private func processFrame(pixelBuffer: CVPixelBuffer, timestamp: CMTime, duration: Double) async {
        do {
            let cachedMask = maskCache.mask(for: timestamp)
            let rawMask: ForegroundMask

            if let cachedMask {
                rawMask = cachedMask
            } else {
                rawMask = try await buildMask(from: pixelBuffer, timestamp: timestamp)
                maskCache.store(rawMask, for: timestamp)
            }

            let smoothedMask = try temporalSmoother.smooth(rawMask, factor: effectSettings.temporalSmoothing)
            let cgImage = try renderer.renderOverlay(
                frameBuffer: pixelBuffer,
                foregroundMask: smoothedMask.pixelBuffer,
                settings: effectSettings
            )
            let image = NSImage(cgImage: cgImage, size: .zero)
            await MainActor.run {
                self.overlayImage = image
                self.currentTime = timestamp.seconds
                self.duration = duration.isFinite ? duration : self.duration
            }
        } catch {
            await MainActor.run {
                self.statusMessage = "Effect pipeline error: \(error.localizedDescription)"
            }
        }
    }

    private func buildMask(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> ForegroundMask {
        switch effectSettings.maskMode {
        case .visionOnly:
            return try await foregroundMaskProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp)
        case .depthFused:
            async let depthTask = depthEstimator.estimateDepth(from: pixelBuffer, timestamp: timestamp)
            async let foregroundTask = foregroundMaskProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp)
            let depthMap = try? await depthTask
            let foregroundMask = try? await foregroundTask
            return try maskFusion.fuse(
                depthMap: depthMap,
                foregroundMask: foregroundMask,
                cutoff: effectSettings.depthCutoff,
                effectStrength: effectSettings.effectStrength
            ) ?? foregroundMask ?? makeEmptyMaskLike(pixelBuffer, timestamp: timestamp)
        case .auto:
            async let depthTask = depthEstimator.estimateDepth(from: pixelBuffer, timestamp: timestamp)
            async let foregroundTask = foregroundMaskProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp)
            let depthMap = try? await depthTask
            let foregroundMask = try? await foregroundTask
            return try maskFusion.fuse(
                depthMap: depthMap,
                foregroundMask: foregroundMask,
                cutoff: effectSettings.depthCutoff,
                effectStrength: effectSettings.effectStrength
            ) ?? foregroundMask ?? makeEmptyMaskLike(pixelBuffer, timestamp: timestamp)
        }
    }

    private func prebufferMasks(videoURL: URL, startTime: CMTime, settings: EffectSettings) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 512, height: 512)

        let stepSeconds = max(1.0 / 15.0, settings.analysisInterval)
        let frameCount = 12
        let times: [CMTime] = (0..<frameCount).map { index in
            CMTime(seconds: startTime.seconds + Double(index) * stepSeconds, preferredTimescale: 600)
        }

        for (index, time) in times.enumerated() {
            try Task.checkCancellation()

            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let pixelBuffer = try makePixelBuffer(from: cgImage)
            let mask = try await buildMaskForBuffer(pixelBuffer, timestamp: time, settings: settings)
            maskCache.store(mask, for: time)

            await MainActor.run {
                self.bufferProgress = Double(index + 1) / Double(frameCount)
            }
        }
    }

    private func buildMaskForBuffer(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime, settings: EffectSettings) async throws -> ForegroundMask {
        switch settings.maskMode {
        case .visionOnly:
            return try await foregroundMaskProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp)
        case .depthFused, .auto:
            async let depthTask = depthEstimator.estimateDepth(from: pixelBuffer, timestamp: timestamp)
            async let foregroundTask = foregroundMaskProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp)
            let depthMap = try? await depthTask
            let foregroundMask = try? await foregroundTask
            return try maskFusion.fuse(
                depthMap: depthMap,
                foregroundMask: foregroundMask,
                cutoff: settings.depthCutoff,
                effectStrength: settings.effectStrength
            ) ?? foregroundMask ?? makeEmptyMaskLike(pixelBuffer, timestamp: timestamp)
        }
    }

    private func makePixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw DepthEstimatorError.modelUnavailable
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        prebufferImageContext.render(
            CIImage(cgImage: image),
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    private func makeEmptyMaskLike(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> ForegroundMask {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        _ = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes as CFDictionary,
            &buffer
        )

        if let buffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetDataSize(buffer))
            }
            return ForegroundMask(pixelBuffer: buffer, confidence: 0, timestamp: timestamp)
        }

        return ForegroundMask(pixelBuffer: pixelBuffer, confidence: 0, timestamp: timestamp)
    }

    private func observePlayerState() {
        observationTokens.append(
            player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor in
                    self?.isPlaying = player.rate > 0
                }
            }
        )

        observationTokens.append(
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.temporalSmoother.reset()
                    self?.refreshDuration()
                }
            }
        )
    }

    private func refreshDuration() {
        guard let asset = player.currentItem?.asset else {
            duration = 0
            return
        }

        Task {
            let loadedDuration = try? await asset.load(.duration)
            await MainActor.run {
                self.duration = loadedDuration?.seconds ?? 0
            }
        }
    }
}
