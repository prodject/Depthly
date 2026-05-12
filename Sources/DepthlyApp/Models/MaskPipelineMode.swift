import Foundation

enum MaskPipelineMode: String, CaseIterable, Identifiable {
    case auto
    case visionOnly
    case depthFused

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .visionOnly: return "Vision Only"
        case .depthFused: return "Depth Fused"
        }
    }
}
