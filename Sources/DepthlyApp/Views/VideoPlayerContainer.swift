import AVFoundation
import SwiftUI

struct VideoPlayerContainer: View {
    let player: AVPlayer
    let overlayImage: CGImage?
    let videoSize: CGSize
    let borderThickness: CGFloat
    let isEffectEnabled: Bool

    private var videoAspectRatio: CGFloat {
        let width = max(videoSize.width, 1)
        let height = max(videoSize.height, 1)
        return width / height
    }

    private var canvasAspectRatio: CGFloat {
        videoAspectRatio
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let canvasRect = fitRect(aspectRatio: canvasAspectRatio, in: bounds)
            let playerRect = canvasRect

            ZStack {
                Color.black

                AVPlayerViewRepresentable(player: player)
                    .frame(width: playerRect.width, height: playerRect.height)
                    .position(x: playerRect.midX, y: playerRect.midY)

                if isEffectEnabled, let overlayImage {
                    Image(decorative: overlayImage, scale: 1.0)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: canvasRect.width, height: canvasRect.height)
                        .position(x: canvasRect.midX, y: canvasRect.midY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
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
}
