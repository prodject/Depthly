import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackOutputRouting: ObservableObject {
    @Published var isExternalPlaybackActive = false

    private var cancellable: AnyCancellable?

    func attach(to player: AVPlayer) {
        player.allowsExternalPlayback = true

        cancellable = player.publisher(for: \.isExternalPlaybackActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isExternalPlaybackActive = isActive
            }
    }
}
