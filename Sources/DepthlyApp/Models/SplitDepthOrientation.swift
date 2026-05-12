import Foundation

enum SplitDepthOrientation: String, CaseIterable, Identifiable {
    case auto
    case vertical
    case horizontal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        }
    }
}
