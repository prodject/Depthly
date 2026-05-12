import AVFoundation
import SwiftUI

struct VideoPlayerContainer: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.bind(player: viewModel.player, overlayProvider: viewModel, settings: viewModel.effectSettings)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.bind(player: viewModel.player, overlayProvider: viewModel, settings: viewModel.effectSettings)
        nsView.needsDisplay = true
        nsView.subviews.forEach { $0.needsDisplay = true }
    }
}

final class PlayerContainerView: NSView {
    private let playerView = PlayerLayerView()
    private let barsView = SplitDepthBarsView()
    private let overlayView = SplitDepthOverlayView()

    private weak var player: AVPlayer?
    private weak var overlayProvider: PlayerOverlayProviding?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.wantsLayer = true

        addSubview(playerView)
        addSubview(barsView)
        addSubview(overlayView)
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bind(player: AVPlayer, overlayProvider: PlayerOverlayProviding, settings: EffectSettings) {
        if self.player !== player {
            playerView.player = player
            self.player = player
        }

        if self.overlayProvider !== overlayProvider {
            self.overlayProvider = overlayProvider
            overlayView.overlayProvider = overlayProvider
        }

        playerView.isHidden = settings.viewMaskOnly
        barsView.settings = settings
        barsView.isHidden = true
        needsLayout = true
        overlayView.needsDisplay = true
        barsView.needsDisplay = true
    }

    override func layout() {
        super.layout()

        playerView.frame = bounds
        let videoRect = playerView.videoRect
        let targetRect = videoRect.isEmpty ? bounds : videoRect
        barsView.frame = targetRect
        overlayView.frame = targetRect

        barsView.needsDisplay = true
        overlayView.needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}

protocol PlayerOverlayProviding: AnyObject {
    @MainActor
    var overlayImage: NSImage? { get }
}

final class SplitDepthOverlayView: NSView {
    weak var overlayProvider: PlayerOverlayProviding? {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()
        overlayProvider?.overlayImage?.draw(in: bounds)
    }
}

final class PlayerLayerView: NSView {
    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            fatalError("PlayerLayerView must be layer-backed with AVPlayerLayer.")
        }
        return playerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var videoRect: CGRect {
        playerLayer.videoRect
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
