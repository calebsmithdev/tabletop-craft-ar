// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TabletopCraft",
    platforms: [.visionOS("27.0"), .macOS(.v15)],
    products: [
        .library(name: "TabletopCore", targets: ["TabletopCore"]),
        .library(name: "TabletopRender", targets: ["TabletopRender"]),
        .library(name: "TabletopSpatial", targets: ["TabletopSpatial"])
    ],
    targets: [
        .target(name: "TabletopCore"),
        .target(name: "TabletopRender", dependencies: ["TabletopCore"],
                resources: [.process("Shaders")]),
        .target(name: "TabletopSpatial", dependencies: ["TabletopCore", "TabletopRender"]),
        .testTarget(name: "TabletopCoreTests", dependencies: ["TabletopCore"])
    ],
    swiftLanguageModes: [.v6]
)
