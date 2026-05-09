import SwiftUI

struct EffectControlsView: View {
    @Binding var isEffectEnabled: Bool
    @Binding var settings: EffectSettings
    @Binding var processingMode: PlayerViewModel.ProcessingMode
    @Binding var showMaskPreview: Bool
    let availableDepthModels: [DepthModelOption]
    let selectedDepthModelID: String
    let depthModelStatus: String
    let isLoadingDepthModel: Bool
    let onSelectDepthModel: (String) -> Void
    let isBufferingDepth: Bool
    let bufferProgress: Double
    let bufferStatus: String
    let isBufferedDepthReady: Bool
    let onPrepareBuffer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split-depth")
                        .font(.headline)
                    Text("Three vertical bars, local rendering, no server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $isEffectEnabled)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Depth model")
                    Spacer()
                    Text(isLoadingDepthModel ? "Loading..." : depthModelStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Picker(
                    "Depth model",
                    selection: Binding(
                        get: { selectedDepthModelID },
                        set: { onSelectDepthModel($0) }
                    )
                ) {
                    ForEach(availableDepthModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Processing mode")
                Picker(
                    "Processing mode",
                    selection: $processingMode
                ) {
                    ForEach(PlayerViewModel.ProcessingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Buffered effect")
                    Spacer()
                    Text(bufferStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    onPrepareBuffer()
                } label: {
                    HStack(spacing: 8) {
                        if isBufferingDepth {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(isBufferingDepth ? "Buffering..." : (isBufferedDepthReady ? "Rebuild buffer" : "Precompute buffer"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
                .disabled(isBufferingDepth)

                if isBufferingDepth {
                    ProgressView(value: bufferProgress)
                } else if isBufferedDepthReady {
                    Label("Ready for playback", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(processingMode == .live ? "Live mode ignores the buffer." : "Effect will fall back to live inference until the buffer is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SliderRow(
                title: "Depth cutoff",
                value: $settings.depthCutoff,
                range: 0.0...1.0,
                suffix: String(format: "%.2f", settings.depthCutoff)
            )

            SliderRow(
                title: "Bar thickness",
                value: Binding(
                    get: { Double(settings.borderThickness) },
                    set: { settings.borderThickness = CGFloat($0) }
                ),
                range: 0.0...160.0,
                suffix: "\(Int(settings.borderThickness)) px"
            )

            SliderRow(
                title: "Edge softness",
                value: Binding(
                    get: { Double(settings.edgeSoftness) },
                    set: { settings.edgeSoftness = CGFloat($0) }
                ),
                range: 0.0...60.0,
                suffix: "\(Int(settings.edgeSoftness)) px"
            )

            SliderRow(
                title: "Effect strength",
                value: $settings.effectStrength,
                range: 0.0...2.0,
                suffix: String(format: "%.2f", settings.effectStrength)
            )

            SliderRow(
                title: "Temporal smoothing",
                value: $settings.temporalSmoothing,
                range: 0.0...1.0,
                suffix: String(format: "%.2f", settings.temporalSmoothing)
            )

            SliderRow(
                title: "Foreground displacement",
                value: Binding(
                    get: { Double(settings.foregroundDisplacement) },
                    set: { settings.foregroundDisplacement = CGFloat($0) }
                ),
                range: 0.0...120.0,
                suffix: "\(Int(settings.foregroundDisplacement)) px"
            )

            Toggle("Invert depth mask", isOn: $settings.invertDepthMask)
            Toggle("Debug mask preview", isOn: $showMaskPreview)
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}
