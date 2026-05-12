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

                Button(viewModel.isBuffering ? "Buffering..." : "Buffer") {
                    viewModel.bufferPlayback()
                }
                .disabled(viewModel.isBuffering)

                Spacer()

                Toggle("Split Depth", isOn: Binding(
                    get: { viewModel.effectSettings.isEnabled },
                    set: { viewModel.setEffectEnabled($0) }
                ))
                .toggleStyle(.switch)

                Toggle("View Mask", isOn: Binding(
                    get: { viewModel.effectSettings.viewMaskOnly },
                    set: { viewModel.setViewMaskOnly($0) }
                ))
                .toggleStyle(.switch)
            }

            if viewModel.isBuffering {
                ProgressView(value: viewModel.bufferProgress)
                    .progressViewStyle(.linear)
            }
        }
    }

    private var effectPanel: some View {
        GroupBox("Effect Controls") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Preset")
                    Picker("", selection: Binding(
                        get: { viewModel.selectedPreset },
                        set: { viewModel.applyPreset($0) }
                    )) {
                        ForEach(EffectPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Spacer()
                }
                GridRow {
                    Text("Mask Mode")
                    Picker("", selection: Binding(
                        get: { viewModel.effectSettings.maskMode },
                        set: { viewModel.setMaskMode($0) }
                    )) {
                        ForEach(MaskPipelineMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Spacer()
                }
                GridRow {
                    Text("Vertical Bars")
                    Toggle("", isOn: Binding(
                        get: { viewModel.effectSettings.verticalBarsEnabled },
                        set: { viewModel.setVerticalBarsEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Picker("", selection: Binding(
                        get: { viewModel.effectSettings.verticalBarDivisionCount },
                        set: { viewModel.setVerticalBarDivisionCount($0) }
                    )) {
                        ForEach(SplitDepthVerticalDivisionCount.allCases) { count in
                            Text(count.displayName).tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!viewModel.effectSettings.verticalBarsEnabled)
                    Spacer()
                }
                GridRow {
                    Text("Vertical Size")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.verticalBarThickness },
                        set: { viewModel.setVerticalBarThickness($0) }
                    ), in: 0.01...0.12)
                    .disabled(!viewModel.effectSettings.verticalBarsEnabled)
                    Text("\(viewModel.effectSettings.verticalBarThickness, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Horizontal Bars")
                    Toggle("", isOn: Binding(
                        get: { viewModel.effectSettings.horizontalBarsEnabled },
                        set: { viewModel.setHorizontalBarsEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Spacer()
                }
                GridRow {
                    Text("Horizontal Size")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.horizontalBarThickness },
                        set: { viewModel.setHorizontalBarThickness($0) }
                    ), in: 0.01...0.12)
                    .disabled(!viewModel.effectSettings.horizontalBarsEnabled)
                    Text("\(viewModel.effectSettings.horizontalBarThickness, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Cutoff")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.depthCutoff },
                        set: { viewModel.effectSettings.depthCutoff = $0; viewModel.selectedPreset = .custom }
                    ), in: 0...1)
                    Text("\(viewModel.effectSettings.depthCutoff, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Softness")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.edgeSoftness },
                        set: { viewModel.effectSettings.edgeSoftness = $0; viewModel.selectedPreset = .custom }
                    ), in: 0...1)
                    Text("\(viewModel.effectSettings.edgeSoftness, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Strength")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.effectStrength },
                        set: { viewModel.effectSettings.effectStrength = $0; viewModel.selectedPreset = .custom }
                    ), in: 0...1)
                    Text("\(viewModel.effectSettings.effectStrength, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
                }
                GridRow {
                    Text("Smoothing")
                    Slider(value: Binding(
                        get: { viewModel.effectSettings.temporalSmoothing },
                        set: { viewModel.effectSettings.temporalSmoothing = $0; viewModel.selectedPreset = .custom }
                    ), in: 0...1)
                    Text("\(viewModel.effectSettings.temporalSmoothing, specifier: "%.2f")")
                        .frame(width: 52, alignment: .trailing)
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
