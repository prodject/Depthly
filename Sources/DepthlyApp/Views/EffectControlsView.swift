import SwiftUI

struct EffectControlsView: View {
    @Binding var isEffectEnabled: Bool
    @Binding var settings: EffectSettings

    var body: some View {
        GroupBox("Split-depth") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enable effect", isOn: $isEffectEnabled)

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
            .padding(.vertical, 2)
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
