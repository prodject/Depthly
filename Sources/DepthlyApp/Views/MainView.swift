import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var scrubProgress: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 18) {
            header

            VideoPlayerContainer(
                player: viewModel.player,
                overlayImage: viewModel.overlayImage,
                videoSize: viewModel.videoSize,
                borderThickness: viewModel.effectSettings.borderThickness,
                isEffectEnabled: viewModel.isEffectEnabled
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
        }
        .padding(20)
        .background(background)
        .onAppear {
            scrubProgress = viewModel.bindingProgress()
        }
        .onChange(of: viewModel.currentTime) { _, _ in
            guard !isScrubbing else { return }
            scrubProgress = viewModel.bindingProgress()
        }
        .onChange(of: viewModel.duration) { _, _ in
            if !isScrubbing { scrubProgress = viewModel.bindingProgress() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Depthly")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(viewModel.statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Open Video") {
                viewModel.openVideoFile()
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { scrubProgress },
                        set: { scrubProgress = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            viewModel.seek(to: scrubProgress)
                        }
                    }
                )

                HStack {
                    Text(formatTime(viewModel.currentTime))
                    Spacer()
                    Text(formatTime(viewModel.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            HStack(spacing: 14) {
                Button(viewModel.isPlaying ? "Pause" : "Play") {
                    viewModel.togglePlayPause()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { viewModel.volume },
                        set: { viewModel.setVolume($0) }
                    ), in: 0...1)
                    .frame(width: 200)
                }

                Spacer()
            }

            EffectControlsView(
                isEffectEnabled: $viewModel.isEffectEnabled,
                settings: $viewModel.effectSettings,
                availableDepthModels: viewModel.availableDepthModels,
                selectedDepthModelID: viewModel.selectedDepthModelID,
                depthModelStatus: viewModel.depthModelStatus,
                isLoadingDepthModel: viewModel.isLoadingDepthModel,
                onSelectDepthModel: { id in
                    viewModel.selectDepthModel(id: id)
                }
            )
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(red: 0.08, green: 0.09, blue: 0.11)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remaining = total % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }
}
