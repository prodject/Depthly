import AVFoundation
import AppKit
import Combine
import CoreMedia
import CoreVideo
import Foundation
import UniformTypeIdentifiers

final class PlayerViewModel: ObservableObject, PlayerOverlayProviding {
    @Published var overlayImage: NSImage?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false
    @Published var volume: Double = 1.0
    @Published var effectSettings: EffectSettings = .default
    @Published var statusMessage: String = "Open a local video to begin."
    @Published var hasVideoLoaded: Bool = false
    @Published var videoSize: CGSize = .zero
    @Published var preprocessingProgress: Double = 0
    @Published var isPreprocessingMasks: Bool = false

    let player = AVPlayer()

    private let frameProvider = AVPlayerItemFrameProvider()
    private let maskTimeline = ForegroundMaskTimeline()
    private let frameProcessor: SplitDepthFrameProcessor
    private let maskPreprocessor = VideoMaskPreprocessor()
    private let airPlayCoordinator = AirPlayCoordinator()

    private var displayLink: CVDisplayLink?
    private let renderQueue = DispatchQueue(label: "Depthly.render.queue", qos: .userInitiated)
    private var currentRenderTask: Task<Void, Never>?
    private var preprocessingTask: Task<Void, Never>?
    private var pendingFrame: PendingFrame?
    private var observationTokens: [NSKeyValueObservation] = []
    private var timeObserverToken: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var loadedAsset: AVAsset?
    private var lastPreprocessedMaskSettings = MaskSettingsSnapshot(settings: .default)

    private struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let itemTime: CMTime
        let settings: EffectSettings
    }

    private struct MaskSettingsSnapshot: Equatable {
        let depthCutoff: Double
        let edgeSoftness: Double
        let temporalSmoothing: Double

        init(settings: EffectSettings) {
            depthCutoff = settings.depthCutoff
            edgeSoftness = settings.edgeSoftness
            temporalSmoothing = settings.temporalSmoothing
        }
    }

    init() {
        frameProcessor = SplitDepthFrameProcessor(timeline: maskTimeline)
        player.automaticallyWaitsToMinimizeStalling = true
        airPlayCoordinator.configure(player: player)
        volume = Double(player.volume)
        startRenderLoop()
        installTimeObserver()
        observePlayerState()
        observeEffectSettings()
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        frameProvider.detach()
        renderQueue.async { [weak self] in
            self?.currentRenderTask?.cancel()
            self?.currentRenderTask = nil
            self?.pendingFrame = nil
        }
        preprocessingTask?.cancel()
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
        loadedAsset = asset
        let item = AVPlayerItem(asset: asset)

        frameProvider.detach()
        frameProvider.attach(to: item)

        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        player.play()

        hasVideoLoaded = true
        overlayImage = nil
        currentTime = 0
        duration = 0
        statusMessage = url.lastPathComponent
        preprocessingProgress = 0
        isPreprocessingMasks = false
        lastPreprocessedMaskSettings = MaskSettingsSnapshot(settings: effectSettings)
        refreshDuration()
        resetProcessingState(clearOverlay: false)
        Task {
            await frameProcessor.reset()
        }
        startMaskPreprocessing(for: asset)
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    await MainActor.run {
                        self.videoSize = .zero
                    }
                    return
                }

                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                let transformedSize = naturalSize.applying(preferredTransform)

                await MainActor.run {
                    self.videoSize = CGSize(
                        width: abs(transformedSize.width),
                        height: abs(transformedSize.height)
                    )
                }
            } catch {
                await MainActor.run {
                    self.videoSize = .zero
                }
            }
        }
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
        player.seek(to: target) { [weak self] _ in
            DispatchQueue.main.async {
                self?.currentTime = target.seconds
                self?.overlayImage = nil
            }
        }
    }

    func updateVolume(_ newValue: Double) {
        volume = max(0.0, min(1.0, newValue))
        player.volume = Float(volume)
    }

    func setEffectEnabled(_ enabled: Bool) {
        effectSettings.isEnabled = enabled
        if !enabled {
            overlayImage = nil
            resetProcessingState(clearOverlay: false)
            Task {
                await frameProcessor.reset()
            }
        } else {
            resetProcessingState(clearOverlay: false)
        }
    }

    private func startRenderLoop() {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link
        else {
            return
        }

        displayLink = link
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let viewModel = Unmanaged<PlayerViewModel>.fromOpaque(userInfo).takeUnretainedValue()
            viewModel.renderQueue.async {
                viewModel.renderTick()
            }
            return kCVReturnSuccess
        }, selfPointer)
        CVDisplayLinkStart(link)
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = seconds
            }

            if let duration = self.player.currentItem?.duration.seconds, duration.isFinite {
                self.duration = duration
            }
        }
    }

    private func renderTick() {
        let settings = effectSettings
        guard settings.isEnabled, player.currentItem != nil else {
            return
        }

        let playerTime = player.currentTime()
        guard let (pixelBuffer, itemTime) = frameProvider.copyCurrentPixelBuffer(at: playerTime) else {
            return
        }

        let timestamp = itemTime.seconds
        guard timestamp.isFinite else { return }
        pendingFrame = PendingFrame(pixelBuffer: pixelBuffer, itemTime: itemTime, settings: settings)
        processLatestPendingFrame()
    }

    private func processLatestPendingFrame() {
        guard currentRenderTask == nil, let pendingFrame else { return }

        self.pendingFrame = nil
        let frameProcessor = frameProcessor
        let queue = renderQueue

        currentRenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                queue.async { [weak self] in
                    guard let self else { return }
                    self.currentRenderTask = nil
                    self.processLatestPendingFrame()
                }
            }

            do {
                let cgImage = try await frameProcessor.processFrame(
                    frameBuffer: pendingFrame.pixelBuffer,
                    timestamp: pendingFrame.itemTime,
                    settings: pendingFrame.settings
                )

                guard !Task.isCancelled else { return }

                let image = NSImage(cgImage: cgImage, size: .zero)
                await MainActor.run {
                    guard self.effectSettings.isEnabled else { return }
                    self.overlayImage = image
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.statusMessage = "Effect pipeline error: \(error.localizedDescription)"
                }
            }
        }
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

    private func resetProcessingState(clearOverlay: Bool) {
        renderQueue.async { [weak self] in
            self?.currentRenderTask?.cancel()
            self?.currentRenderTask = nil
            self?.pendingFrame = nil
        }

        if clearOverlay {
            overlayImage = nil
        }
    }

    func bestOverlayImage(for playbackTime: Double) -> NSImage? {
        overlayImage
    }

    private func observeEffectSettings() {
        $effectSettings
            .removeDuplicates()
            .sink { [weak self] settings in
                guard let self else { return }
                let snapshot = MaskSettingsSnapshot(settings: settings)
                guard snapshot != self.lastPreprocessedMaskSettings else { return }
                guard self.hasVideoLoaded, let asset = self.loadedAsset else { return }

                self.lastPreprocessedMaskSettings = snapshot
                self.overlayImage = nil
                self.resetProcessingState(clearOverlay: false)
                Task {
                    await self.frameProcessor.reset()
                }
                self.startMaskPreprocessing(for: asset)
            }
            .store(in: &cancellables)
    }

    private func startMaskPreprocessing(for asset: AVAsset) {
        preprocessingTask?.cancel()
        isPreprocessingMasks = true
        preprocessingProgress = 0

        let settings = effectSettings
        preprocessingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            do {
                try await self.maskPreprocessor.preprocess(
                    asset: asset,
                    settings: settings,
                    timeline: self.maskTimeline
                ) { progress, status in
                    self.preprocessingProgress = progress
                    self.statusMessage = status
                }

                await MainActor.run {
                    self.isPreprocessingMasks = false
                    self.preprocessingProgress = 1
                    if self.hasVideoLoaded {
                        self.statusMessage = "Masks ready"
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isPreprocessingMasks = false
                }
            } catch {
                await MainActor.run {
                    self.isPreprocessingMasks = false
                    self.statusMessage = "Mask preprocessing failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
