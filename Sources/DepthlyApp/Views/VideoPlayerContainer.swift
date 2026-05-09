import AVFoundation
import SwiftUI

struct VideoPlayerContainer: View {
    let player: AVPlayer
    let overlayImage: CGImage?
    let videoSize: CGSize
    let borderThickness: CGFloat

    private var outerAspectRatio: CGFloat {
        let width = max(videoSize.width, 1)
        let height = max(videoSize.height, 1)
        let outerWidth = width + borderThickness * 2
        let outerHeight = height + borderThickness * 2
        return outerWidth / outerHeight
    }

    var body: some View {
        ZStack {
            Color.black

            AVPlayerViewRepresentable(player: player)
                .padding(borderThickness)

            if let overlayImage {
                Image(decorative: overlayImage, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(outerAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
    }
}
