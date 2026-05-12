import AVKit
import SwiftUI

struct VideoPlayerContainer: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.bind(player: viewModel.player, overlayProvider: viewModel, videoSize: viewModel.videoSize)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.bind(player: viewModel.player, overlayProvider: viewModel, videoSize: viewModel.videoSize)
        nsView.needsDisplay = true
        nsView.subviews.forEach { $0.needsDisplay = true }
    }
}

final class PlayerContainerView: NSView {
    private let playerView = AVPlayerView()
    private let barsView = SplitDepthBarsView()
    private let overlayView = SplitDepthOverlayView()

    private weak var player: AVPlayer?
    private weak var overlayProvider: PlayerOverlayProviding?
    private var videoSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true

        barsView.translatesAutoresizingMaskIntoConstraints = false
        barsView.isHidden = false

        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.contentRectProvider = { [weak self] in
            guard let self else { return .zero }
            let fitRect = self.fitRect(aspectRatio: self.videoAspectRatio, in: self.bounds)
            return fitRect.isEmpty ? self.bounds : fitRect
        }

        addSubview(playerView)
        addSubview(barsView)
        addSubview(overlayView)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            barsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            barsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            barsView.topAnchor.constraint(equalTo: topAnchor),
            barsView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bind(player: AVPlayer, overlayProvider: PlayerOverlayProviding, videoSize: CGSize) {
        if self.player !== player {
            playerView.player = player
            self.player = player
        }

        self.videoSize = videoSize

        if self.overlayProvider !== overlayProvider {
            self.overlayProvider = overlayProvider
            overlayView.overlayProvider = overlayProvider
        }

        barsView.settings = viewModelSettings(from: overlayProvider)
        barsView.needsDisplay = true
        overlayView.needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        overlayView.needsDisplay = true
    }

    private var videoAspectRatio: CGFloat {
        let width = max(videoSize.width, 1)
        let height = max(videoSize.height, 1)
        return width / height
    }

    private func fitRect(aspectRatio: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspectRatio > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let boundsAspect = bounds.width / max(bounds.height, 1)
        if boundsAspect > aspectRatio {
            let width = bounds.height * aspectRatio
            let x = bounds.midX - width / 2
            return CGRect(x: x, y: bounds.minY, width: width, height: bounds.height).integral
        } else {
            let height = bounds.width / aspectRatio
            let y = bounds.midY - height / 2
            return CGRect(x: bounds.minX, y: y, width: bounds.width, height: height).integral
        }
    }

    private func viewModelSettings(from overlayProvider: PlayerOverlayProviding) -> EffectSettings {
        if let viewModel = overlayProvider as? PlayerViewModel {
            return viewModel.effectSettings
        }
        return .default
    }
}

protocol PlayerOverlayProviding: AnyObject {
    var overlayImage: NSImage? { get }
}

final class SplitDepthOverlayView: NSView {
    weak var overlayProvider: PlayerOverlayProviding? {
        didSet {
            needsDisplay = true
        }
    }

    var contentRectProvider: (() -> CGRect)?

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
        guard let overlayImage = overlayProvider?.overlayImage else { return }
        let targetRect = contentRectProvider?() ?? bounds
        overlayImage.draw(in: targetRect)
    }
}
