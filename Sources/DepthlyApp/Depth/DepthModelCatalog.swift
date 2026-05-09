import Foundation

struct DepthModelOption: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case mock
        case visionPersonSegmentation
        case coreML
    }

    let id: String
    let displayName: String
    let fileURL: URL?
    let kind: Kind

    var isMock: Bool { kind == .mock }
    var isBuiltInVision: Bool { kind == .visionPersonSegmentation }
    var isCoreML: Bool { kind == .coreML }

    static let mock = DepthModelOption(
        id: "mock",
        displayName: "Mock foreground mask",
        fileURL: nil,
        kind: .mock
    )

    static let visionPersonSegmentation = DepthModelOption(
        id: "vision.person.segmentation",
        displayName: "Vision Person Segmentation",
        fileURL: nil,
        kind: .visionPersonSegmentation
    )
}

enum DepthModelCatalog {
    static func discoverModels() -> [DepthModelOption] {
        var options: [DepthModelOption] = [
            DepthModelOption.visionPersonSegmentation,
            DepthModelOption.mock
        ]

        let urls = discoverModelURLs()
        for url in urls {
            options.append(
                DepthModelOption(
                    id: url.path,
                    displayName: readableName(from: url),
                    fileURL: url,
                    kind: .coreML
                )
            )
        }

        return options
    }

    private static func discoverModelURLs() -> [URL] {
        let fm = FileManager.default
        let rootCandidates = [
            Bundle.module.resourceURL?.appendingPathComponent("Models"),
            URL(fileURLWithPath: "Sources/DepthlyApp/Resources/Models", isDirectory: true),
            URL(fileURLWithPath: "models", isDirectory: true)
        ].compactMap { $0 }

        var urls: [URL] = []
        for root in rootCandidates {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if ext == "mlpackage" || ext == "mlmodelc" || ext == "mlmodel" {
                    urls.append(url)
                }
            }
        }

        let unique = Dictionary(grouping: urls, by: { $0.path }).compactMap { $0.value.first }
        return unique.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func readableName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".mlpackage") {
            name = String(name.dropLast(".mlpackage".count))
        }
        return name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}
