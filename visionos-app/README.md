# visionos-app

A native visionOS client for TabletopCraft, in development. It renders the same server stream as the [Quest app](../quest-app) as a flat-colour table-top miniature.

**Status: M0 (scaffolding) and M1a/M1b (flat-colour world in the app) are implemented; device verification is outstanding.** The macOS package builds and its tests pass. The app builds for the visionOS simulator, where the lit cube (M0) and the connected world (M1b) have been observed. Device tracking, privacy prompts, GPU performance, M0's device exit criteria (a cube that stays fixed under head motion and full display rate) and hosted CI are not verified. Simulator timing does not establish device performance.

The app contains no Mojang or game assets. It is not an official Minecraft product.

## M1a: engine-free core

`TabletopCore` ports the Quest JSON/protocol, WebSocket link, sectioned/delta snapshot assembly, world updates, flat-colour greedy meshing, CPU batches, session helpers, preferences, pairing and unicast LAN discovery. Port headers name the C# source and revision. The link uses Network.framework behind `LinkTransport`; pairing tokens use injectable `TokenStorage` (memory implementation in the core; the app supplies a Keychain adapter, see M1b). The core has no UI or Metal dependency and never mirrors Z or reverses triangles for Unity. Pack models, fluids, lighting and biome shading remain M3 seams.

The macOS diagnostic executable accepts the shared fixtures and a WebSocket endpoint:

```sh
swift run tabletop-cli --fixture ../tools/fixtures/chunk_snapshot.json
swift run -c release tabletop-cli --mesh ../tools/fixtures/chunk_snapshot_sections.json --hash
swift run tabletop-cli --live ws://HOST:8765/tabletop --token TOKEN --seconds 10
```

Delta fixtures load `chunk_snapshot_sections.json` from the same directory as their base. Per-section hashes match C# `MeshTests.Hash` exactly (vertex, UV, colour, index and light bytes in emission order). The aggregate canonical hash uses FNV-1a over sorted quad records, retaining each quad's vertex order, float bits, UVs, colours, light codes, pass and local triangle indices. Decode timing includes file loading; mesh timing excludes printing and hashing. Golden C# comparisons disable light/biome shading for this flat-colour milestone. Unknown-block fallback colours use deterministic FNV-1a because .NET's string hash varies between processes. App wiring and rendering are M1b; M1a itself changed no app screens.

## M1b: connected flat-colour miniature

The app connects to a server, meshes the streamed region with `TabletopCore` and draws it through `TabletopSpatial` and Compositor Services.

- **Connection.** `App/ConnectionModel.swift` and the SwiftUI launcher take a server address, normalise it and persist it through `AppPrefs` in `Application Support/TabletopCraft/prefs.json`. `mesh_workers` defaults to 3 and is clamped to 1...8.
- **Session.** `LinkClient` and `WorldSession` (a serial actor) apply snapshots and updates. Each dispatch round takes one immutable copy-on-write world that is meshed (`build` + `buildSpecials`) on a bounded task group, one batch per 2×2 column of sections. Buffers are prepared in the background. The compositor loop takes a try-lock mailbox and swaps in finished batches within 3 ms. The full region is re-meshed on each snapshot; the previous completed generation remains drawn until all replacement meshes and GPU buffers are ready, then the renderer swaps the complete generation in one step. Superseded incomplete generations are discarded. The Quest's reuse optimisation is not ported; section comparison/planning is opt-in and skipped by the app.
- **Rendering.** Reverse Z, no Z mirror (`TableFrame` is right-handed), per-face shade, sRGB decode and stereo box culling. Flat colours only: transparent shapes are drawn opaque, water backs are excluded, and there is no giant avatar.
- **Placement.** The region's longer x/z span is fitted to 0.5 m with the scale clamped to 0.002...0.1, centred in x/z with y=0 on the table. On the first head placement the table sits 0.75 m ahead and 0.35 m below the head.
- **Lifecycle.** Closing the table keeps the link, world and batches. Going to the background sends `bye` and stops; becoming active after that background pause reconnects once to the previously submitted address, not the draft in the text field. Inactive/active focus transitions keep the current link; connecting to the same address while linked or connecting is a no-op.
- **Pairing.** The Keychain adapter (`KeychainTokenStorage`) keeps tokens; none are written to prefs. The launcher shows a 6-digit code. In the server console, run `tabletop pair CODE` using that code. The app stores the token in the Keychain; a required-pairing session continues trusted on the same connection, while an open-server session reconnects with its token.
- **Launch arguments** (Debug builds): `-server URL`, `-connectOnLaunch`, `-openTableOnLaunch`, `-findServersOnLaunch`, `-dedicatedLayout` and `-debugCube`, which adds the M0 cube for renderer diagnostics.

Verified with the simulator: 54 Swift tests pass, including C# parity, golden meshes, a real 4 MiB NW snapshot, culling, winding, stale handoff, session revocation and storage failure; the simulator build has zero errors (one existing AppIntents warning); a live session connected with RTT, world and dimensions; terrain, a resize to 64×96×64 and a live fill; LAN discovery (TCP fallback, later an actual UDP reply); a required pairing code, a Keychain save and a relaunch trusted without a new code (`auth.require-pairing` restored to false afterwards). Closing and reopening the table kept the session, and background/foreground logs showed `bye` followed by a reconnect. Simulator frame timings do not establish device performance.

Not verified: device tracking, privacy permissions, local-network permission on a device and GPU performance. Simulator timing is not device evidence. Later milestones: M2 planes and poses; M3 textures, lighting and true transparent passes.

### Snapshot and discovery bounds

Snapshot block, biome and light decoders reject non-positive dimensions, overflowing volumes and oversized allocations before expanding RLE data. The hard ceiling is `352 * 384 * 352` cells (47,579,136), matching the Paper plugin's default `max_region`; a known `welcome.limits.max_blocks` applies a smaller ceiling with 25% headroom, capped at that hard ceiling. Invalid snapshots follow the existing `bad_snapshot` response path and preserve the current scene. This ceiling bounds individual decoded arrays; it is not a total-memory budget.

LAN discovery runs blocking BSD socket waits on a dedicated concurrent Dispatch queue bridged through continuations, with at most 48 TCP checks per sweep. Cancellation drains active checks; the socket worker checks cancellation between waits of at most 25 ms. Swift's cooperative executor remains available for link keepalives.

### Run against a local server

The Keychain needs a signed build (an unsigned one fails with error -34018 when it saves a token). `tools/build-sim.sh` signs ad hoc by default:

```sh
tools/build-sim.sh
xcrun simctl install booted DerivedData/Build/Products/Debug-xrsimulator/TabletopCraft.app
xcrun simctl launch booted com.tabletopcraft.ar.visionos \
  -server ws://127.0.0.1:8765/tabletop -connectOnLaunch -openTableOnLaunch
```

The simulator shares the Mac's network, so loopback reaches a plugin server on the same Mac. `tools/run-sim.sh` still rebuilds unsigned, so don't use it when you need Keychain persistence. On a device use `ws://SERVER-IP:8765/tabletop`; the local-network permission flow on a device is unverified. A real Xcode build uses the optional `Signing.xcconfig` below with your own team.

## What is implemented (M0)

- **Launcher.** A SwiftUI window with Open table and Close table buttons, the project name, and the legal line "NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT." Scene phase is tracked, and the table closes when the app goes to the background.
- **Mixed immersive space.** An `ImmersiveSpace` with `.mixed` immersion hosts a Compositor Services layer.
- **Own Metal renderer.** The original cyan cube remains available with `-debugCube`, 10 cm on a side and lit. Placement comes from the first head pose (0.75 m ahead and 0.35 m below), rather than a fixed world height.
  - Layout: `layered` with vertex amplification (one pass for both eyes) when available, with a per-view `dedicated` fallback.
  - Depth: reverse Z, `depth32Float`.
  - Foveation: used when supported, through the drawable's rasterization rate maps.
- **Render loop.** The `TableRenderLoop` actor runs on a dedicated `.userInteractive` task executor. At most 3 frames are in flight, and the loop can be stopped at any time through `RenderControl`, even while the compositor is paused.
- **`TabletopCore`.** Engine-free pose math in `TableFrame`, covered by `TableFrameTests`. Coordinates are right-handed metres, +Y up, −Z forward, with no Z mirror. Transforms are named `aFromB`: `tableFromDevice = tableFromOrigin * originFromDevice`. `ProtocolLook` derives yaw and pitch with the formula from [docs/PROTOCOL.md](../docs/PROTOCOL.md) §3.

## Layout

| Path | Contents |
| --- | --- |
| `Package.swift` | Swift tools 6.2 manifest. Libraries `TabletopCore`, `TabletopRender`, `TabletopSpatial`, plus the `tabletop-cli` executable (`Sources/TabletopCLI`) |
| `Sources/TabletopCore` | Protocol, link, meshing, session state and pose math, no UI or Metal |
| `Sources/TabletopRender` | Metal cube and batch renderers and shaders |
| `Sources/TabletopSpatial` | Compositor Services layer configuration, stereo views, render loop, `WorldSession`, Keychain storage (visionOS only) |
| `Tests/TabletopCoreTests` | Unit tests |
| `App/` | The SwiftUI app target: `TabletopCraftApp.swift`, `ConnectionModel.swift`, `Info.plist`, `App.xcconfig` |
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

It runs `xcodegen generate` and then `xcodebuild` with ad-hoc signing (`CODE_SIGN_IDENTITY=-`, so the Keychain works; no team needed), into `DerivedData/`. It targets the simulator named "Apple Vision Pro". Pick another one by name or UDID:

```sh
SIMULATOR=<name-or-udid> tools/build-sim.sh
```

To call `xcodebuild` yourself, give it an explicit destination for a visionOS simulator that exists on your machine (`xcrun simctl list devices`):

```sh
xcodebuild -project TabletopCraft.xcodeproj -scheme TabletopCraft \
  -destination 'platform=visionOS Simulator,id=<simulator-udid>' \
  CODE_SIGN_IDENTITY=- build
```

**Run in the simulator:**

```sh
tools/run-sim.sh                    # build, install, launch, open the table
tools/run-sim.sh -dedicatedLayout   # force the per-view fallback layout
```

`run-sim.sh` builds, installs and launches a Debug build with `-openTableOnLaunch`. Extra arguments are passed to the app. `-openTableOnLaunch` and `-dedicatedLayout` exist only in Debug builds.

The M0 cube (now `-debugCube`) sits on the table, which is placed from the first head pose (0.75 m ahead, 0.35 m below eye level). It is not attached to the simulated furniture. Real table placement is M2.

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

## Known gaps

- No physical Vision Pro verification yet (see Status).
- The simulator has no passthrough and cannot show device performance or foveation behaviour.
- No textures, lighting, true transparency, input, sound or table-plane/pose integration yet (M2, M3).
