import Foundation

enum SplitDepthVerticalDivisionCount: Int, CaseIterable, Identifiable {
    case two = 2
    case three = 3
    case four = 4

    var id: Int { rawValue }

    var displayName: String {
        String(rawValue)
    }
}
