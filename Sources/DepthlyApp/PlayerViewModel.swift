import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreMedia
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: ObservableObject, PlayerOverlayProviding {
    @Published var overlayImage: NSImage?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false
    @Published var volume: Double = 1.0
    @Published var effectSettings: EffectSettings = .default
    @Published var statusMessage: String = "Open a local video to begin."

    let player = AVPlayer()

    private let frameProvider = AVPlayerItemFrameProvider()
    private let foregroundMaskProvider: ForegroundMaskProviding = AdaptiveForegroundMaskProvider()
    private let renderer = SplitDepthRenderer()
    private let airPlayCoordinator = AirPlayCoordinator()

    private var renderTimer: DispatchSourceTimer?
    private let renderQueue = DispatchQueue(label: "Depthly.render.queue", qos: .userInitiated)
    private var observationTokens: [NSKeyValueObservation] = []

    init() {
        airPlayCoordinator.configure(player: player)
        volume = Double(player.volume)
        startRenderLoop()
        observePlayerState()
    }

    deinit {
        renderTimer?.cancel()
        frameProvider.detach()
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

        frameProvider.detach()
        frameProvider.attach(to: item)

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
        guard effectSettings.isEnabled, let item = player.currentItem else {
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
            let foregroundMask = try await foregroundMaskProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp)
            let cgImage = try renderer.renderOverlay(frameBuffer: pixelBuffer, foregroundMask: foregroundMask.pixelBuffer, settings: effectSettings)
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
}
