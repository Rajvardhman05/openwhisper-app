// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenWhisper",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "OpenWhisper",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "OpenWhisper",
            exclude: ["Info.plist", "OpenWhisper.entitlements"],
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
