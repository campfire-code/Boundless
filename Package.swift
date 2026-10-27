// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Boundless",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BoundlessCore"),
        .target(name: "VirtualDisplayAPI", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "Boundless", dependencies: ["BoundlessCore", "VirtualDisplayAPI"]),
        .testTarget(name: "BoundlessCoreTests", dependencies: ["BoundlessCore"]),
    ],
    swiftLanguageModes: [.v5]
)
