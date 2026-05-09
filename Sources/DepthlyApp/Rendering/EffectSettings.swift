import CoreGraphics

struct EffectSettings: Equatable, Sendable {
    var depthCutoff: Double = 0.45
    var borderThickness: CGFloat = 18
    var edgeSoftness: CGFloat = 12
    var effectStrength: Double = 0.70
    var temporalSmoothing: Double = 0.75
    var foregroundDisplacement: CGFloat = 28
    var invertDepthMask: Bool = false
    var showMaskPreview: Bool = false

    static let `default` = EffectSettings()
}
