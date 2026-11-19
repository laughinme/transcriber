// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transcriber",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TranscriberCore"),
        .executableTarget(name: "Transcriber", dependencies: ["TranscriberCore"]),
        .testTarget(name: "TranscriberCoreTests", dependencies: ["TranscriberCore"]),
    ],
    swiftLanguageModes: [.v5]
)
