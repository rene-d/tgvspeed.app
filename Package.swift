// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TGVSpeed",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TGVSpeed",
            path: "Sources/TGVSpeed",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "tgvsim",
            path: "Sources/tgvsim",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
