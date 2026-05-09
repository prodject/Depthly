// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Depthly",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "DepthlyApp", targets: ["DepthlyApp"])
    ],
    targets: [
        .executableTarget(
            name: "DepthlyApp",
            path: "Sources/DepthlyApp",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .define("CI_SILENCE_GL_DEPRECATION")
            ]
        )
    ]
)
