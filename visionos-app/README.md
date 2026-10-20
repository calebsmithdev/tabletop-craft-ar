# visionos-app

A native visionOS client for TabletopCraft, in development. It will render the same server stream as the [Quest app](../quest-app) as a table-top miniature.

**Status: M0 (scaffolding) is implemented and awaiting hardware verification.** The macOS package builds and its pose tests pass. The app builds for the visionOS simulator, where the lit cube has been observed. M0's device exit criteria (a cube that stays fixed under head motion and full display rate) and hosted CI are not yet verified. Simulator timing does not establish device performance.

The app contains no Mojang or game assets and has no networking yet. It is not an official Minecraft product.

## What is implemented

- **Launcher.** A SwiftUI window with Open table and Close table buttons, the project name, and the legal line "NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT." Scene phase is tracked, and the table closes when the app goes to the background.
- **Mixed immersive space.** An `ImmersiveSpace` with `.mixed` immersion hosts a Compositor Services layer.
- **Own Metal renderer.** One original cyan cube, 10 cm on a side and lit, fixed in room space at (0, 0.8, −0.75) metres from the origin (0.75 m forward, 0.8 m up).
  - Layout: `layered` with vertex amplification (one pass for both eyes) when available, with a per-view `dedicated` fallback.
  - Depth: reverse Z, `depth32Float`.
  - Foveation: used when supported, through the drawable's rasterization rate maps.
- **Render loop.** The `TableRenderLoop` actor runs on a dedicated `.userInteractive` task executor. At most 3 frames are in flight, and the loop can be stopped at any time through `RenderControl`, even while the compositor is paused.
- **`TabletopCore`.** Engine-free pose math in `TableFrame`, covered by `TableFrameTests`. Coordinates are right-handed metres, +Y up, −Z forward, with no Z mirror. Transforms are named `aFromB`: `tableFromDevice = tableFromOrigin * originFromDevice`. `ProtocolLook` derives yaw and pitch with the formula from [docs/PROTOCOL.md](../docs/PROTOCOL.md) §3.

## Layout

| Path | Contents |
| --- | --- |
| `Package.swift` | Swift tools 6.2 manifest. Libraries `TabletopCore`, `TabletopRender`, `TabletopSpatial` |
| `Sources/TabletopCore` | Pose math, no UI and no platform dependencies |
| `Sources/TabletopRender` | Metal cube renderer and shaders |
| `Sources/TabletopSpatial` | Compositor Services layer configuration, stereo views, render loop (visionOS only) |
| `Tests/TabletopCoreTests` | Unit tests |
| `App/` | The SwiftUI app target: `TabletopCraftApp.swift`, `Info.plist`, `App.xcconfig` |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec for the Xcode project |
| `tools/` | `build-sim.sh`, `run-sim.sh` |

## Toolchain pins

| | |
| --- | --- |
| Xcode | 27.0 (build 27A266a) |
| visionOS SDK and minimum deployment target | 27.0 |
| Swift compiler | 6.4, language mode 6, strict concurrency `complete` |
| Swift tools version | 6.2 |
| Package minimum for macOS | 15 (so `swift build` and `swift test` run on a Mac) |

Don't bump these to make errors go away.

Concurrency: the app target defaults to `MainActor` isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`). The package libraries have no UI and no default isolation, and the renderer is an actor.

## Build

All commands run from `visionos-app/`. You need XcodeGen (`brew install xcodegen`).

```sh
cd visionos-app
```

**Engine-free package** (no simulator needed):

```sh
swift build
swift test
```

**Xcode project:** the app project is generated, not checked in.

```sh
xcodegen generate
```

`project.yml` has a `preGenCommand` that reads `../VERSION` and writes the git-ignored `Version.xcconfig`, which sets `MARKETING_VERSION`.

**Simulator build:**

```sh
tools/build-sim.sh
```

It runs `xcodegen generate` and then `xcodebuild` with `CODE_SIGNING_ALLOWED=NO`, into `DerivedData/`. It targets the simulator named "Apple Vision Pro". Pick another one by name or UDID:

```sh
SIMULATOR=<name-or-udid> tools/build-sim.sh
```

To call `xcodebuild` yourself, give it an explicit destination for a visionOS simulator that exists on your machine (`xcrun simctl list devices`):

```sh
xcodebuild -project TabletopCraft.xcodeproj -scheme TabletopCraft \
  -destination 'platform=visionOS Simulator,id=<simulator-udid>' \
  CODE_SIGNING_ALLOWED=NO build
```

**Run in the simulator:**

```sh
tools/run-sim.sh                    # build, install, launch, open the table
tools/run-sim.sh -dedicatedLayout   # force the per-view fallback layout
```

`run-sim.sh` builds, installs and launches a Debug build with `-openTableOnLaunch`. Extra arguments are passed to the app. `-openTableOnLaunch` and `-dedicatedLayout` exist only in Debug builds.

The cube uses the fixed ARKit-origin placement above. The simulator's synthetic head may start at y=0 rather than a standing height; in that case look upward to see the cube at y=0.8. It is not attached to the simulated furniture. Real table placement is M2.

## Signing and device

Simulator builds need no signing. For a device:

```sh
cp Signing.xcconfig.template Signing.xcconfig
# set DEVELOPMENT_TEAM to your own team in Signing.xcconfig
xcodegen generate
xcodebuild -project TabletopCraft.xcodeproj -scheme TabletopCraft \
  -destination 'generic/platform=visionOS' -allowProvisioningUpdates build
```

To install on a headset, open the generated project in Xcode, select the connected Vision Pro, and run. Team IDs and signing identities stay in your local `Signing.xcconfig` and never go in the repo.

Git-ignored: `.build/`, `.swiftpm/`, `DerivedData/`, `build/`, the generated `*.xcodeproj/`, `Signing.xcconfig`, `Version.xcconfig` and `xcuserdata/`.

## CI

The `visionos-core` job in [.github/workflows/ci.yml](../.github/workflows/ci.yml) runs `swift build` and `swift test` on `macos-latest`. There is no simulator build in CI, because the runner's Xcode 27 availability is unverified.

## Known gaps in M0

- No physical Vision Pro verification yet (see Status).
- The simulator has no passthrough and cannot show device performance or foveation behaviour.
- No networking, world rendering, input or sound; those come next.
