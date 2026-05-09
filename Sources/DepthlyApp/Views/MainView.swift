import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var scrubProgress: Double = 0
    @State private var isScrubbing = false
    @State private var isSettingsPopoverPresented = false

    private var hasVideoLoaded: Bool {
        viewModel.videoSize != .zero
    }

    var body: some View {
        ZStack {
            backdrop

            MetalVideoSurface(viewModel: viewModel)
            .ignoresSafeArea()

            vignette

            if viewModel.isLoadingDepthModel || viewModel.isBufferingDepth {
                preparationOverlay
            }

            if !hasVideoLoaded {
                emptyState
            }

            VStack(spacing: 0) {
                topChrome
                Spacer()
                bottomChrome
            }
            .padding(20)
        }
        .background(WindowChromeConfigurator().frame(width: 0, height: 0))
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

    private var topChrome: some View {
        HStack(alignment: .top, spacing: 12) {
            infoChip

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                iconButton(title: "Open Video", systemImage: "folder.badge.plus") {
                    viewModel.openVideoFile()
                }
                settingsBubble
            }
        }
    }

    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            HStack(spacing: 14) {
                glassButton(title: viewModel.isPlaying ? "Pause" : "Play", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill") {
                    viewModel.togglePlayPause()
                }
                .disabled(!viewModel.canStartPlayback)
                .opacity(viewModel.canStartPlayback ? 1.0 : 0.55)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { viewModel.volume },
                            set: { viewModel.setVolume($0) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 220)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text(formatTime(viewModel.currentTime))
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(formatTime(viewModel.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(16)
        .background(glassSurface(cornerRadius: 24))
    }

    private var infoChip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Depthly")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(viewModel.activeProcessingStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(glassSurface(cornerRadius: 22))
    }

    private var settingsBubble: some View {
        Button {
            isSettingsPopoverPresented.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        )
        .popover(isPresented: $isSettingsPopoverPresented, arrowEdge: .top) {
            ScrollView {
                EffectControlsView(
                    isEffectEnabled: $viewModel.isEffectEnabled,
                    settings: $viewModel.effectSettings,
                    showMaskPreview: Binding(
                        get: { viewModel.effectSettings.showMaskPreview },
                        set: { viewModel.effectSettings.showMaskPreview = $0 }
                    ),
                    availableDepthModels: viewModel.availableDepthModels,
                    selectedDepthModelID: viewModel.selectedDepthModelID,
                    depthModelStatus: viewModel.depthModelStatus,
                    isLoadingDepthModel: viewModel.isLoadingDepthModel,
                    onSelectDepthModel: { id in
                        viewModel.selectDepthModel(id: id)
                    },
                    isBufferingDepth: viewModel.isBufferingDepth,
                    bufferProgress: viewModel.bufferProgress,
                    bufferStatus: viewModel.bufferStatus,
                    isBufferedDepthReady: viewModel.isBufferedDepthReady,
                    onPrepareBuffer: {
                        viewModel.prepareDepthBuffer()
                    }
                )
                .padding(18)
            }
            .frame(width: 380, height: 520)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.14),
                        Color.white.opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .background(.ultraThinMaterial)
            )
        }
    }

    private var preparationOverlay: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                if viewModel.isBufferingDepth {
                    ProgressView(value: viewModel.bufferProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                }

                VStack(spacing: 4) {
                    Text(viewModel.isLoadingDepthModel ? "Loading model" : "Buffering depth")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(viewModel.isLoadingDepthModel ? viewModel.depthModelStatus : viewModel.bufferStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(viewModel.playbackLockReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.9))
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .background(glassSurface(cornerRadius: 28))
            .frame(maxWidth: 320)
        }
        .transition(.opacity.combined(with: .scale))
        .animation(.easeInOut(duration: 0.2), value: viewModel.isBufferingDepth || viewModel.isLoadingDepthModel)
    }

    private func iconButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .background(glassSurface(cornerRadius: 18))
    }

    private func glassButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .background(glassSurface(cornerRadius: 18))
    }

    private func glassSurface(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.26), radius: 16, y: 8)
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                    Color(red: 0.08, green: 0.09, blue: 0.12),
                    Color(red: 0.03, green: 0.03, blue: 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 460
            )

            RadialGradient(
                colors: [
                    Color(red: 0.25, green: 0.55, blue: 0.9).opacity(0.18),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private var vignette: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.28),
                Color.clear,
                Color.black.opacity(0.30)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text("Open a local video")
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Text("The player stays fully local. Settings live in the floating bubble.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button {
                viewModel.openVideoFile()
            } label: {
                Label("Choose Video", systemImage: "folder.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(glassSurface(cornerRadius: 18))
        }
        .padding(28)
        .background(glassSurface(cornerRadius: 30))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remaining = total % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }
}
