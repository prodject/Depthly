import AVKit
import SwiftUI

struct VideoPlayerContainer: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.bind(player: viewModel.player, overlayProvider: viewModel)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.bind(player: viewModel.player, overlayProvider: viewModel)
        nsView.needsDisplay = true
        nsView.subviews.forEach { $0.needsDisplay = true }
    }
}

final class PlayerContainerView: NSView {
    private let playerView = AVPlayerView()
    private let overlayView = SplitDepthOverlayView()

    private weak var player: AVPlayer?
    private weak var overlayProvider: PlayerOverlayProviding?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true

        overlayView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(playerView)
        addSubview(overlayView)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bind(player: AVPlayer, overlayProvider: PlayerOverlayProviding) {
        if self.player !== player {
            playerView.player = player
            self.player = player
        }

        if self.overlayProvider !== overlayProvider {
            self.overlayProvider = overlayProvider
            overlayView.overlayProvider = overlayProvider
        }

        overlayView.needsDisplay = true
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
