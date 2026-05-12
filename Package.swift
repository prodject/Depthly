// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Depthly",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "DepthlyApp",
            targets: ["DepthlyApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "DepthlyApp",
            path: "Sources/DepthlyApp"
        )
    ]
)
