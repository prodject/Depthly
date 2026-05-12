import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreMedia
import Foundation
import UniformTypeIdentifiers

private let prebufferImageContext = CIContext(options: nil)

private struct BufferSignature: Equatable {
    let videoPath: String
    let settingsKey: String
}

@MainActor
final class PlayerViewModel: ObservableObject, PlayerOverlayProviding {
    @Published var overlayImage: NSImage?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false
    @Published var volume: Double = 1.0
    @Published var effectSettings: EffectSettings = .default
    @Published var selectedPreset: EffectPreset = .custom
    @Published var isBuffering: Bool = false
    @Published var bufferProgress: Double = 0
    @Published var isBufferReady: Bool = false
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
    private var bufferSignature: BufferSignature?

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
        maskCache.configure(for: url, persistent: effectSettings.autoBufferPlayback)
        frameProvider.detach()
        frameProvider.attach(to: item)
        temporalSmoother.reset()
        maskCache.clearMemory()
        isBufferReady = false
        bufferSignature = nil

        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        player.pause()
        statusMessage = effectSettings.autoBufferPlayback ? "Preparing full buffer..." : url.lastPathComponent

        Task { [weak self] in
            guard let self else { return }
            await self.startPlaybackAfterLoad()
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if effectSettings.isEnabled && effectSettings.autoBufferPlayback {
                if isCurrentBufferValid() {
                    player.play()
                } else {
                    bufferPlayback(resumeAfterBuffer: true)
                }
            } else {
                player.play()
            }
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let clamped = max(0.0, min(1.0, fraction))
        let target = CMTime(seconds: duration * clamped, preferredTimescale: 600)
        temporalSmoother.reset()
        maskCache.clearMemory()
        isBufferReady = false
        bufferSignature = nil
        player.seek(to: target)
    }

    func updateVolume(_ newValue: Double) {
        volume = max(0.0, min(1.0, newValue))
        player.volume = Float(volume)
    }

    func setEffectEnabled(_ enabled: Bool) {
        effectSettings.isEnabled = enabled
        selectedPreset = .custom
        if !enabled {
            overlayImage = nil
            temporalSmoother.reset()
            isBufferReady = false
            bufferSignature = nil
        }
    }

    func setViewMaskOnly(_ enabled: Bool) {
        effectSettings.viewMaskOnly = enabled
        selectedPreset = .custom
    }

    func setMaskMode(_ mode: MaskPipelineMode) {
        effectSettings.maskMode = mode
        temporalSmoother.reset()
        maskCache.removeAll()
        isBufferReady = false
        bufferSignature = nil
        selectedPreset = .custom
    }

    func setVerticalBarsEnabled(_ enabled: Bool) {
        effectSettings.verticalBarsEnabled = enabled
        maskCache.removeAll()
        isBufferReady = false
        bufferSignature = nil
        selectedPreset = .custom
    }

    func setVerticalBarDivisionCount(_ count: SplitDepthVerticalDivisionCount) {
        effectSettings.verticalBarDivisionCount = count
        maskCache.removeAll()
        isBufferReady = false
        bufferSignature = nil
        selectedPreset = .custom
    }

    func setVerticalBarThickness(_ value: Double) {
        effectSettings.verticalBarThickness = value
        maskCache.removeAll()
        isBufferReady = false
        bufferSignature = nil
        selectedPreset = .custom
    }

    func setHorizontalBarsEnabled(_ enabled: Bool) {
        effectSettings.horizontalBarsEnabled = enabled
        maskCache.removeAll()
        isBufferReady = false
        bufferSignature = nil
        selectedPreset = .custom
    }

    func setHorizontalBarThickness(_ value: Double) {
        effectSettings.horizontalBarThickness = value
        maskCache.removeAll()
        isBufferReady = false
        bufferSignature = nil
        selectedPreset = .custom
    }

    func applyPreset(_ preset: EffectPreset) {
        selectedPreset = preset
        switch preset {
        case .custom:
            break
        case .release100:
            effectSettings.isEnabled = true
            effectSettings.viewMaskOnly = false
            effectSettings.autoBufferPlayback = false
            effectSettings.maskMode = .visionOnly
            effectSettings.orientation = .auto
            effectSettings.depthCutoff = 0.68
            effectSettings.borderThickness = 0.08
            effectSettings.verticalBarsEnabled = true
            effectSettings.verticalBarDivisionCount = .three
            effectSettings.verticalBarThickness = 0.06
            effectSettings.horizontalBarsEnabled = true
            effectSettings.horizontalBarThickness = 0.08
            effectSettings.edgeSoftness = 0.18
            effectSettings.effectStrength = 0.0
            effectSettings.temporalSmoothing = 0.0
            effectSettings.analysisScale = 0.5
            effectSettings.analysisInterval = 1.0 / 12.0
            temporalSmoother.reset()
            maskCache.removeAll()
            isBufferReady = false
            bufferSignature = nil
            statusMessage = "Applied Release 1.0.0 preset"
            if currentVideoURL != nil, duration > 0, isPlaying {
                player.play()
            }
        }
    }

    func bufferPlayback(resumeAfterBuffer: Bool = true) {
        guard !isBuffering, let url = currentVideoURL, duration > 0 else {
            return
        }

        maskCache.configure(for: url, persistent: true)
        player.pause()
        isBuffering = true
        bufferProgress = 0
        statusMessage = "Buffering masks..."

        bufferTask?.cancel()
        let settingsSnapshot = effectSettings
        let startTime = player.currentTime()
        let signature = makeBufferSignature(videoURL: url, settings: settingsSnapshot)
        isBufferReady = false
        bufferSignature = signature

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
                    self.isBufferReady = true
                    self.bufferSignature = signature
                    self.statusMessage = "Buffer ready"
                    if resumeAfterBuffer {
                        self.player.play()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isBuffering = false
                    self.isBufferReady = false
                    self.bufferSignature = nil
                    self.statusMessage = "Buffering failed: \(error.localizedDescription)"
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
                maskCache.store(rawMask, for: timestamp, persistent: effectSettings.autoBufferPlayback)
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
            ) ?? foregroundMask ?? Self.makeEmptyMaskLike(pixelBuffer, timestamp: timestamp)
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
            ) ?? foregroundMask ?? Self.makeEmptyMaskLike(pixelBuffer, timestamp: timestamp)
        }
    }

    func noteManualOverride() {
        if selectedPreset != .custom {
            selectedPreset = .custom
        }
    }

    private func prebufferMasks(videoURL: URL, startTime: CMTime, settings: EffectSettings) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 512, height: 512)

        let durationSeconds = player.currentItem?.duration.seconds ?? duration
        guard durationSeconds.isFinite, durationSeconds > startTime.seconds else {
            throw DepthEstimatorError.modelUnavailable
        }

        let stepSeconds = max(1.0 / 15.0, settings.analysisInterval)
        let totalFrames = max(1, Int(ceil((durationSeconds - startTime.seconds) / stepSeconds)) + 1)
        let batchSize = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        var processedFrames = 0
        var pendingFrames: [(CMTime, CGImage)] = []

        for index in 0..<totalFrames {
            try Task.checkCancellation()

            let time = CMTime(seconds: startTime.seconds + Double(index) * stepSeconds, preferredTimescale: 600)
            guard time.seconds <= durationSeconds + 0.001 else { break }

            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            pendingFrames.append((time, cgImage))

            if pendingFrames.count >= batchSize {
                try await Self.processPrebufferBatch(
                    pendingFrames,
                    settings: settings,
                    maskCache: maskCache,
                    depthEstimator: depthEstimator,
                    foregroundMaskProvider: foregroundMaskProvider,
                    maskFusion: maskFusion
                )
                processedFrames += pendingFrames.count
                pendingFrames.removeAll(keepingCapacity: true)
                await MainActor.run {
                    self.bufferProgress = Double(processedFrames) / Double(totalFrames)
                }
            }
        }

        if !pendingFrames.isEmpty {
            try await Self.processPrebufferBatch(
                pendingFrames,
                settings: settings,
                maskCache: maskCache,
                depthEstimator: depthEstimator,
                foregroundMaskProvider: foregroundMaskProvider,
                maskFusion: maskFusion
            )
            processedFrames += pendingFrames.count
            await MainActor.run {
                self.bufferProgress = Double(processedFrames) / Double(totalFrames)
            }
        }
    }

    nonisolated private static func processPrebufferBatch(
        _ frames: [(CMTime, CGImage)],
        settings: EffectSettings,
        maskCache: MaskCache,
        depthEstimator: DepthEstimating,
        foregroundMaskProvider: ForegroundMaskProviding,
        maskFusion: MaskFusion
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (timestamp, cgImage) in frames {
                group.addTask {
                    let pixelBuffer = try Self.makePixelBuffer(from: cgImage)
                    let mask = try await Self.buildMaskForBuffer(
                        pixelBuffer,
                        timestamp: timestamp,
                        settings: settings,
                        depthEstimator: depthEstimator,
                        foregroundMaskProvider: foregroundMaskProvider,
                        maskFusion: maskFusion
                    )
                    maskCache.store(mask, for: timestamp, persistent: true)
                }
            }

            try await group.waitForAll()
        }
    }

    nonisolated private static func buildMaskForBuffer(
        _ pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        settings: EffectSettings,
        depthEstimator: DepthEstimating,
        foregroundMaskProvider: ForegroundMaskProviding,
        maskFusion: MaskFusion
    ) async throws -> ForegroundMask {
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
            ) ?? foregroundMask ?? Self.makeEmptyMaskLike(pixelBuffer, timestamp: timestamp)
        }
    }

    nonisolated private static func makePixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
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

    nonisolated private static func makeEmptyMaskLike(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> ForegroundMask {
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
                    await self?.refreshDuration()
                }
            }
        )
    }

    private func refreshDuration() async {
        guard let asset = player.currentItem?.asset else {
            duration = 0
            return
        }

        let loadedDuration = try? await asset.load(.duration)
        await MainActor.run {
            self.duration = loadedDuration?.seconds ?? 0
        }
    }

    private func startPlaybackAfterLoad() async {
        await refreshDuration()

        guard duration > 0 else {
            statusMessage = currentVideoURL?.lastPathComponent ?? "Ready"
            return
        }

        if effectSettings.isEnabled && effectSettings.autoBufferPlayback {
            bufferPlayback(resumeAfterBuffer: true)
        } else {
            statusMessage = currentVideoURL?.lastPathComponent ?? "Ready"
            player.play()
        }
    }

    private func isCurrentBufferValid() -> Bool {
        guard isBufferReady, let currentVideoURL, effectSettings.autoBufferPlayback else { return false }
        let currentSignature = makeBufferSignature(videoURL: currentVideoURL, settings: effectSettings)
        return bufferSignature == currentSignature
    }

    private func makeBufferSignature(videoURL: URL, settings: EffectSettings) -> BufferSignature {
        BufferSignature(
            videoPath: videoURL.standardizedFileURL.path,
            settingsKey: [
                settings.isEnabled ? "1" : "0",
                settings.viewMaskOnly ? "1" : "0",
                settings.maskMode.rawValue,
                settings.orientation.rawValue,
                String(format: "%.4f", settings.depthCutoff),
                String(format: "%.4f", settings.borderThickness),
                settings.verticalBarsEnabled ? "1" : "0",
                String(settings.verticalBarDivisionCount.rawValue),
                String(format: "%.4f", settings.verticalBarThickness),
                settings.horizontalBarsEnabled ? "1" : "0",
                String(format: "%.4f", settings.horizontalBarThickness),
                String(format: "%.4f", settings.edgeSoftness),
                String(format: "%.4f", settings.effectStrength),
                String(format: "%.4f", settings.temporalSmoothing),
                String(format: "%.4f", settings.analysisScale),
                String(format: "%.4f", settings.analysisInterval)
            ].joined(separator: "|")
        )
    }
}
