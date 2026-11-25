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
        .target(name: "SubmonitorCore"),
        .executableTarget(
            name: "submonitor",
            dependencies: ["CGVirtualDisplayPrivate", "SubmonitorCore"]
        ),
        .testTarget(name: "SubmonitorCoreTests", dependencies: ["SubmonitorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
