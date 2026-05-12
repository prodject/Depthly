import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()

    var body: some View {
        VStack(spacing: 16) {
            header
            playerArea
            controls
            effectPanel
        }
        .padding(16)
        .frame(minWidth: 1100, minHeight: 760)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Depthly")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Spacer()
            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Video") {
                viewModel.openVideo()
            }
            .keyboardShortcut("o")
            RoutePickerButton()
                .frame(width: 44, height: 28)
        }
    }

    private var playerArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)

            VideoPlayerContainer(viewModel: viewModel)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if viewModel.overlayImage == nil {
                VStack(spacing: 8) {
                    Image(systemName: "video")
                        .font(.system(size: 42))
                    Text("Open a local file to start playback")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button(viewModel.isPlaying ? "Pause" : "Play") {
                    viewModel.togglePlayback()
                }

                Slider(value: Binding(
                    get: { viewModel.duration > 0 ? viewModel.currentTime / viewModel.duration : 0 },
                    set: { viewModel.seek(to: $0) }
                ))

                Text(timeLabel(viewModel.currentTime))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                Text("/")
                    .foregroundStyle(.secondary)
                Text(timeLabel(viewModel.duration))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .leading)
            }

            HStack {
                Text("Volume")
                Slider(value: Binding(
                    get: { viewModel.volume },
                    set: { viewModel.updateVolume($0) }
                ), in: 0...1)
                .frame(width: 220)

                Spacer()

                Toggle("Split Depth", isOn: Binding(
                    get: { viewModel.effectSettings.isEnabled },
                    set: { viewModel.setEffectEnabled($0) }
                ))
                .toggleStyle(.switch)

                Toggle("Bars", isOn: Binding(
                    get: { viewModel.effectSettings.barsEnabled },
                    set: { viewModel.effectSettings.barsEnabled = $0 }
                ))
                .toggleStyle(.switch)
            }
        }
    }

    private var effectPanel: some View {
        GroupBox("Split Depth Controls") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Cutoff")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.depthCutoff },
                        set: { viewModel.effectSettings.depthCutoff = $0 }
                    ), in: 0...1)
                    Text("\(viewModel.effectSettings.depthCutoff, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Bar Thickness")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.borderThickness },
                        set: { viewModel.effectSettings.borderThickness = $0 }
                    ), in: 0.02...0.18)
                    Text("\(viewModel.effectSettings.borderThickness, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Vertical Bars")
                    Toggle("", isOn: Binding(
                        get: { viewModel.effectSettings.verticalBarsEnabled },
                        set: { viewModel.effectSettings.verticalBarsEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Spacer()
                }
                GridRow {
                    Text("Vertical Width")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.verticalBarThickness },
                        set: { viewModel.effectSettings.verticalBarThickness = $0 }
                    ), in: 0.01...0.12)
                    .disabled(!viewModel.effectSettings.verticalBarsEnabled)
                    Text("\(viewModel.effectSettings.verticalBarThickness, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Horizontal Bars")
                    Toggle("", isOn: Binding(
                        get: { viewModel.effectSettings.horizontalBarsEnabled },
                        set: { viewModel.effectSettings.horizontalBarsEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Spacer()
                }
                GridRow {
                    Text("Horizontal Height")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.horizontalBarThickness },
                        set: { viewModel.effectSettings.horizontalBarThickness = $0 }
                    ), in: 0.01...0.12)
                    .disabled(!viewModel.effectSettings.horizontalBarsEnabled)
                    Text("\(viewModel.effectSettings.horizontalBarThickness, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Softness")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.edgeSoftness },
                        set: { viewModel.effectSettings.edgeSoftness = $0 }
                    ), in: 0...1)
                    Text("\(viewModel.effectSettings.edgeSoftness, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Strength")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.effectStrength },
                        set: { viewModel.effectSettings.effectStrength = $0 }
                    ), in: 0...1)
                    Text("\(viewModel.effectSettings.effectStrength, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Smoothing")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.temporalSmoothing },
                        set: { viewModel.effectSettings.temporalSmoothing = $0 }
                    ), in: 0...1)
                    Text("\(viewModel.effectSettings.temporalSmoothing, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Bars Orientation")
                    Picker("", selection: Binding(
                        get: { viewModel.effectSettings.orientation },
                        set: { viewModel.effectSettings.orientation = $0 }
                    )) {
                        ForEach(SplitDepthOrientation.allCases) { orientation in
                            Text(orientation.displayName).tag(orientation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Spacer()
                }
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let remainingSeconds = total % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
