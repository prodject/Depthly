import SwiftUI

struct EffectControlsView: View {
    @Binding var isEffectEnabled: Bool
    @Binding var settings: EffectSettings
    let availableDepthModels: [DepthModelOption]
    let selectedDepthModelID: String
    let depthModelStatus: String
    let isLoadingDepthModel: Bool
    let onSelectDepthModel: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split-depth")
                        .font(.headline)
                    Text("Local rendering, no server")
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

            SliderRow(
                title: "Depth cutoff",
                value: $settings.depthCutoff,
                range: 0.0...1.0,
                suffix: String(format: "%.2f", settings.depthCutoff)
            )

            SliderRow(
                title: "Border thickness",
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
