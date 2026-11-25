// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "submonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CGVirtualDisplayPrivate",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "submonitor",
            dependencies: ["CGVirtualDisplayPrivate"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
