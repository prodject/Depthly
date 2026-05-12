import Foundation

struct EffectSettings: Equatable {
    var isEnabled: Bool = true
    var barsEnabled: Bool = true
    var orientation: SplitDepthOrientation = .auto
    var depthCutoff: Double = 0.68
    var borderThickness: Double = 0.08
    var verticalBarsEnabled: Bool = true
    var verticalBarThickness: Double = 0.06
    var horizontalBarsEnabled: Bool = true
    var horizontalBarThickness: Double = 0.08
    var edgeSoftness: Double = 0.18
    var effectStrength: Double = 1.0
    var temporalSmoothing: Double = 0.86
    var analysisScale: Double = 0.5
    var analysisInterval: Double = 1.0 / 30.0

    static let `default` = EffectSettings()
}
