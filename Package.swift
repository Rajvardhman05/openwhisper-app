// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenWhisper",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3"),
    ],
    targets: [
        .executableTarget(
            name: "OpenWhisper",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "OpenWhisper",
            exclude: ["Info.plist", "OpenWhisper.entitlements"],
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
