import Foundation

enum EffectPreset: String, CaseIterable, Identifiable {
    case custom
    case release100

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .custom: return "Custom"
        case .release100: return "Release 1.0.0"
        }
    }
}
