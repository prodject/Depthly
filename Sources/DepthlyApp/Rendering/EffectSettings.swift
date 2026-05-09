import CoreGraphics

struct EffectSettings: Equatable, Sendable {
    var depthCutoff: Double = 0.34
    var borderThickness: CGFloat = 28
    var edgeSoftness: CGFloat = 12
    var effectStrength: Double = 1.0
    var temporalSmoothing: Double = 0.75
    var foregroundDisplacement: CGFloat = 44
    var invertDepthMask: Bool = false
    var showMaskPreview: Bool = false

    static let `default` = EffectSettings()
}
