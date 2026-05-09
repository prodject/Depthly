import SwiftUI

@main
struct DepthlyApp: App {
    @StateObject private var viewModel = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            MainView(viewModel: viewModel)
                .frame(minWidth: 1200, minHeight: 760)
        }
        .windowStyle(.titleBar)
    }
}
