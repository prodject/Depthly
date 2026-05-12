import AVKit
import SwiftUI

final class AirPlayCoordinator {
    func configure(player: AVPlayer) {
        player.allowsExternalPlayback = true
    }
}

struct RoutePickerButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
