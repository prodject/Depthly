import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @State private var isSettingsPresented = false

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 16) {
                header
                playerArea
                playbackControls
            }
            .padding(20)

            vignette
        }
        .background(WindowChromeConfigurator().frame(width: 0, height: 0))
        .frame(minWidth: 1200, minHeight: 820)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            infoChip

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                actionButton(title: "Open Video", systemImage: "folder.badge.plus") {
                    viewModel.openVideo()
                }
                .keyboardShortcut("o")

                settingsButton

                RoutePickerButton()
                    .frame(width: 42, height: 42)
                    .background(glassSurface(cornerRadius: 18))
            }
        }
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .background(glassSurface(cornerRadius: 18))
        .popover(isPresented: $isSettingsPresented, arrowEdge: .top) {
            ScrollView {
                effectControls
                    .padding(18)
            }
            .frame(width: 420, height: 360)
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

    private var infoChip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Depthly")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(viewModel.hasVideoLoaded ? "Local playback · split-depth preview" : "Open a local video to begin")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(glassSurface(cornerRadius: 22))
    }

    private var playerArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.32), radius: 20, y: 10)

            VideoPlayerContainer(viewModel: viewModel)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            if !viewModel.hasVideoLoaded {
                VStack(spacing: 12) {
                    Image(systemName: "video")
                        .font(.system(size: 42, weight: .light))
                    Text("Open a local file to start playback")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                    Text("Split-depth processing stays on device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding(30)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 460)
    }

    private var playbackControls: some View {
        VStack(spacing: 14) {
            Slider(value: Binding(
                get: { viewModel.duration > 0 ? viewModel.currentTime / viewModel.duration : 0 },
                set: { viewModel.seek(to: $0) }
            ))

            HStack(spacing: 14) {
                actionButton(
                    title: viewModel.isPlaying ? "Pause" : "Play",
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
                ) {
                    viewModel.togglePlayback()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { viewModel.volume },
                        set: { viewModel.updateVolume($0) }
                    ), in: 0...1)
                    .frame(width: 220)
                }

                Spacer()

                HStack(spacing: 12) {
                    Text(formatTime(viewModel.currentTime))
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(formatTime(viewModel.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                Toggle("Split Depth", isOn: Binding(
                    get: { viewModel.effectSettings.isEnabled },
                    set: { viewModel.setEffectEnabled($0) }
                ))
                .toggleStyle(.switch)
            }
        }
        .padding(16)
        .background(glassSurface(cornerRadius: 24))
    }

    private var effectControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split-depth Controls")
                        .font(.headline)
                    Text("Local mask inference, soft edges, no server upload")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(viewModel.effectSettings.isEnabled ? "Active" : "Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Bars enabled")
                    Toggle("", isOn: Binding(
                        get: { viewModel.effectSettings.barsEnabled },
                        set: { viewModel.effectSettings.barsEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Spacer()
                }

                gridRow(
                    title: "Depth cutoff",
                    value: viewModel.effectSettings.depthCutoff,
                    range: 0.0...1.0,
                    binding: Binding(
                        get: { viewModel.effectSettings.depthCutoff },
                        set: { viewModel.effectSettings.depthCutoff = $0 }
                    )
                )

                gridRow(
                    title: "Border thickness",
                    value: viewModel.effectSettings.borderThickness,
                    range: 0.02...0.18,
                    binding: Binding(
                        get: { viewModel.effectSettings.borderThickness },
                        set: { viewModel.effectSettings.borderThickness = $0 }
                    )
                )

                GridRow {
                    Text("Vertical bars")
                    Toggle("", isOn: Binding(
                        get: { viewModel.effectSettings.verticalBarsEnabled },
                        set: { viewModel.effectSettings.verticalBarsEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Spacer()
                }

                gridRow(
                    title: "Vertical width",
                    value: viewModel.effectSettings.verticalBarThickness,
                    range: 0.01...0.12,
                    binding: Binding(
                        get: { viewModel.effectSettings.verticalBarThickness },
                        set: { viewModel.effectSettings.verticalBarThickness = $0 }
                    )
                )

                GridRow {
                    Text("Horizontal bars")
                    Toggle("", isOn: Binding(
                        get: { viewModel.effectSettings.horizontalBarsEnabled },
                        set: { viewModel.effectSettings.horizontalBarsEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Spacer()
                }

                gridRow(
                    title: "Horizontal height",
                    value: viewModel.effectSettings.horizontalBarThickness,
                    range: 0.01...0.12,
                    binding: Binding(
                        get: { viewModel.effectSettings.horizontalBarThickness },
                        set: { viewModel.effectSettings.horizontalBarThickness = $0 }
                    )
                )

                gridRow(
                    title: "Edge softness",
                    value: viewModel.effectSettings.edgeSoftness,
                    range: 0.0...1.0,
                    binding: Binding(
                        get: { viewModel.effectSettings.edgeSoftness },
                        set: { viewModel.effectSettings.edgeSoftness = $0 }
                    )
                )

                gridRow(
                    title: "Effect strength",
                    value: viewModel.effectSettings.effectStrength,
                    range: 0.0...1.0,
                    binding: Binding(
                        get: { viewModel.effectSettings.effectStrength },
                        set: { viewModel.effectSettings.effectStrength = $0 }
                    )
                )

                gridRow(
                    title: "Temporal smoothing",
                    value: viewModel.effectSettings.temporalSmoothing,
                    range: 0.0...1.0,
                    binding: Binding(
                        get: { viewModel.effectSettings.temporalSmoothing },
                        set: { viewModel.effectSettings.temporalSmoothing = $0 }
                    )
                )
            }
        }
        .padding(16)
        .background(glassSurface(cornerRadius: 24))
    }

    private func gridRow(title: String, value: Double, range: ClosedRange<Double>, binding: Binding<Double>) -> some View {
        GridRow {
            Text(title)
            Slider(value: binding, in: range)
            Text(String(format: "%.2f", value))
                .frame(width: 52, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
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
                    Color(red: 0.25, green: 0.55, blue: 0.9).opacity(0.16),
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

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let remainingSeconds = total % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
