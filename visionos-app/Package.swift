// swift-tools-version: 6.2
import PackageDescription

// The diagnostic executable is a macOS host tool, not part of the visionOS app.
var hostProducts: [Product] = []
var hostTargets: [Target] = []
#if os(macOS)
hostProducts.append(.executable(name: "tabletop-cli", targets: ["TabletopCLI"]))
hostTargets.append(.executableTarget(name: "TabletopCLI", dependencies: ["TabletopCore"]))
#endif

let package = Package(
    name: "TabletopCraft",
    platforms: [.visionOS("27.0"), .macOS(.v15)],
    products: [
        .library(name: "TabletopCore", targets: ["TabletopCore"]),
        .library(name: "TabletopRender", targets: ["TabletopRender"]),
        .library(name: "TabletopSpatial", targets: ["TabletopSpatial"])
    ] + hostProducts,
    targets: [
        .target(name: "TabletopCore"),
        .target(name: "TabletopRender", dependencies: ["TabletopCore"],
                resources: [.process("Shaders")]),
        .target(name: "TabletopSpatial", dependencies: ["TabletopCore", "TabletopRender"]),
        .testTarget(name: "TabletopCoreTests", dependencies: ["TabletopCore", "TabletopRender", "TabletopSpatial"])
    ] + hostTargets,
    swiftLanguageModes: [.v6]
)
