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

## M3a: CPU-only textured-world core (ported from the Quest app)

M3a ports the Quest's pack, model and shading pipeline into `TabletopCore`. It is CPU-only: no UI, no GPU upload and no app wiring. **The app is still the flat-colour M1 miniature**, and no screen changed. M3b (GPU atlas upload, shaders, passes, wiring) is not started.

**What the core now has**

- Zip reading (`ZipArchive`, Foundation/zlib), `PngDecoder`, ordered `PackJSON`, block models (`BlockModels`, `BlockModelBaker`, `BlockRandom` and `RandomUv`), `ResourcePackAtlas` with texture mips and animations.
- Biome colours and colormaps, noon light codes, AO and smooth lighting (`BlockShading`, `LightCode`), fluids with waterlogging and flow (`FluidMesher`), piston ghosts and `EyeMedium`.
- A solid/cutout split and the 20-byte `PackedVertex`.
- The no-face-source mesher overloads preserve M1's unlit, fluid-free output. Pass a baked face source explicitly to use M3 lighting and fluids.

**Upload-facing API (for M3b)**

1. One serial owner holds a non-`Sendable` `ResourcePackAtlas(path: jarPath)`.
2. Before a snapshot goes to mesh workers, the owner calls `prewarm(palette)`. The palette includes any moving (`movingShown`) states. Never resolve an unseen state from a worker.
3. `baked()` returns an immutable, `Sendable` `BakedResourcePack`: `faces`, `models`, `shapeOverrides`, `tileSize`, `layerNames`, `layers`, `mips`, `animations`, `solidLayers`, `randomTables`, `colormaps`.
4. The M3b owner then calls `world.applyShapeOverrides(pack.shapeOverrides)` and `world.setColormaps(pack.colormaps)`.
5. Pass `pack.solidLayers` to `SectionMesh.from`; `BatchData.packedBytes()` provides the 20-byte encoding, or `nil` when classic vertices are required.
6. Layer rows are bottom-up and UVs are v-up. The orientation change and the Metal upload are M3b work.

**Remaining M3b work:** GPU texture-array/mip/animation upload, shaders for the packed vertex and solid/cutout/transparent passes, app wiring, and device checks.

**Commands** (run from `visionos-app/`; `TABLETOP_CLIENT_JAR` points at your own client jar, for example `~/Library/Application Support/minecraft/versions/26.2/26.2.jar`)

```sh
swift run -c release tabletop-cli --mesh MODELS.json --jar "$TABLETOP_CLIENT_JAR" --hash --reps 30
# Add --flat-light, --no-light, or --reference-profile as needed.
swift test                           # jar tests skip when TABLETOP_CLIENT_JAR is unset
TABLETOP_CLIENT_JAR="/path/to/client.jar" swift test
```

The default CLI uses the production atlas. The stock C# `MeshTests` profile uses a test stand-in atlas, so compare against it with `--reference-profile`. Optional real goldens: `TABLETOP_M3A_SNAPSHOTS=<dir>`.

**Verified CPU behavior**

- Raw per-section hashes matched C# exactly in 72 cases: 3 real Paper 26.3 snapshots (32×16×32, with models, fluids and waterlogging) × 4 sections × 3 modes (smooth, flat, no-light). C# side: the production atlas adapter and the stock `MeshTests` profile. Hashes cover raw `MeshData` before the Unity mirror.
- The CPU upload digests matched too: pixels, all mips, frames and schedules, solid layers, maps and random tables.
- A frozen source manifest stayed unchanged through three full `swift test` runs without the jar and three with the 26.2 jar and captured fixtures: 15 XCTest plus 110 Swift Testing cases, zero failures. Five input-dependent tests skip when the jar and snapshot variables are unset.
- Debug and Release package builds and `tools/build-sim.sh` passed (zero simulator build errors; the existing AppIntents metadata warning remains). Independent review and its focused follow-up completed; the accepted fixes preserve the M1 app path and reject malformed model bounds safely.

**Limitations:** ZIP64, encrypted and multi-disk archives are unsupported. The real snapshots come from a flat world, not natural terrain. Nothing was verified on a physical device or on the GPU. No game data is in the repo, only hashes and counts.

## M3b: textured Metal miniature and runtime game files

M3b connects M3a to the native app. This section supersedes the historical flat-colour/M3b-not-started status in the M1 and M3a notes above. Game files remain in the user's Application Support directory, outside the app bundle and repository.

- **Files and launcher.** The hello requests `assets_v1`. `AssetProtocol` and the actor-owned `AssetSync` use the current protocol's **SHA-256** (not SHA-1), four ranged requests in flight, resumable `.part` files, a size/date hash cache, and verified atomic installation. The launcher shows PACK name/size/date, download percentage and errors, and imports the user's own zip or client jar through Files. Successful imports select the manual pack until **Use server pack** is chosen. Failed imports preserve the previous file and source selection. M3 downloads only `pack.zip` by default; Debug `-downloadAllAssets` also downloads `entity_models.json` and `sounds.zip` for later milestones.
- **Ownership and reload.** `WorldSession` hands pack loading and prewarming to the cancellable `PackBakeWorker` actor, which alone owns the mutable atlas. Mesh workers receive an immutable `BakedResourcePack` and matching world shapes, colormaps and lighting. New palette entries and `movingShown` states are prewarmed append-only into the same generation, bounded face/model cache resolutions complete atomically and cancellation is observed between states (it is non-sticky and never invalidates the pack), so only the affected dirty sections remesh, and the published atlas's incremental slice writes go into a staged shared buffer, then budgeted GPU blits (all mips, both the atlas and nearest textures) run before the new draw scene is shown; upload dependencies are ordered by shared events and the queue can be reopened. Initial unpublished textures are CPU-initialized. If the layer capacity overflows, `BatchScene` prepares a replacement while the old pack stays visible with its old meshes. A full pack reload still replaces the generation the same way. The render thread consumes completed references.
- **Failed packs.** The session writes `pack-load-failure.txt` before baking an installed pack. Validation failure or process termination during loading leaves it behind, and it prevents the next automatic cached load. Cooperative cancellation restores the prior marker state. The PACK line shows the reason. **Use server pack** explicitly forces a fresh download, and re-importing a pack retries; an ordinary reconnect does not repeat the failed pack. Cancelling `preparePalette` (for example by a disconnect) preserves the existing quarantine state, sets no `packFailure`, and ignores results from a stale connection or load revision. Debug-only `-debugDisconnectDuringPrewarm` triggers one real disconnect 2 ms after palette preparation starts and reconnects 250 ms later; ordinary and release launches are unaffected. If GPU preparation fails, the app falls back to a flat-colour remesh and reports the failure in the status.
- **Pack limits** (`ResourcePackLimits`). A first tile larger than 256 is rejected; later images are resampled to the tile size. At most 1,024 animation frames, 1,024 schedule entries and 2,048 layers. The 256 MiB pixel budget counts independent raw and mip storage for CPU and GPU, nearest and frame duplicates, staging, spare layer capacity, mip scratch, colormaps and a 32-byte-per-source-pixel decode reserve. It excludes ZIP/JSON bytes, meshes, driver alignment and other generations. Shared mip caches avoid repeated CPU copies, and the scene drops its CPU source after upload.
- **Metal.** Animation frame stores and compute staging use unorm storage with sRGB views for copies into the sRGB atlas, so every blit has matching formats and atlas sampling stays sRGB. Texture-array layers include every CPU-built mip and animation frame. The MSL port decodes 20-byte packed vertices or the 32-byte fallback, applies the Quest face shade and colour conversion, preserves tiled/random/flowing UVs, samples texel centres nearby and trilinear mips farther away, and draws solid, cutout, sorted blended and underwater-back ranges. Solid has no discard. Function constants specialize packed/solid/fog/transparent paths; clip planes and daylight are reserved false for M4/M7. Reverse-Z solid and transparent use `greater`; cutout uses `greaterEqual`, the reverse-Z equivalent of Quest's coplanar grass-overlay test.
- **Animation.** At 20 game ticks/s, a blit encoder copies all changed frame mips into stable atlas layers. Interpolated frames use preallocated GPU scratch textures and an encoded-byte blend before the blit, instead of Quest's CPU staging; synthetic tests compare every resulting mip byte against the CPU reference. No frame pixels or texture resources are allocated on the render thread.
- **Eye effects.** A nonblocking probe publishes immutable world generations holding a compact neighbourhood around the head (radius `ceil(0.03 m / blockSize)`, capped at 16 cells, plus a one-cell sampling halo), with no `WorldModel` retention, from the latest table-space head position. The renderer reads only the displayed generation, runs `EyeMediumFilter`, draws the premultiplied background tint first, enables fluid fog, and toggles water's inside faces. When the head outruns the published neighbourhood, or a matching probe has no new sample, the renderer preserves its medium, look and water-vision progress until sampling resumes. A change of displayed generation resets the filter and look, and an empty generation clears old effects. The near plane requests 1 mm clamped to the compositor’s supported minimum; the far plane and reverse-Z convention are preserved. Fluid volumes smaller than that minimum still clip at the eye, so underwater QA needs a sufficiently deep tank. Water fog follows the current Quest `EyeMedium` implementation where older architecture prose differs.
- **Settings.** Advanced launcher controls persist `mipmaps: true`, `smooth_lighting: true`, `min_light: 0.2`, `brightness: 1`, `leaves_inner: true` and `mesh_workers: 3` (clamped to 1...8) through `AppPrefs`. Apply remeshes when CPU shading or leaves change. Stereo view/viewport and transparent-sort storage is reused across frames.

Synthetic tests cover asset offers/frames/ranges/resume/checksums/cache, repeated offers after manual replacement, valid/failed imports, eye generation resets, classic/packed buffer layout, all four index ranges, transparent sort order, atlas layer/mip/frame bytes, pack/mesh generation publication, and every used material pipeline with one and two views, and actual rendered-pixel checks that the water-back range draws only underwater and that fog changes block pixels independently of the background tint. Existing real-jar snapshot parity remains opt-in:

```sh
swift build
swift test
TABLETOP_CLIENT_JAR="/path/to/your/26.2.jar" \
  TABLETOP_M3A_SNAPSHOTS="/path/to/local/snapshots" swift test
tools/build-sim.sh
```

Metal validation (the synthetic render tests compare every uploaded mip and animation byte and cover incremental atlas growth and fallback):

```sh
MTL_DEBUG_LAYER=1 swift test
METAL_DEVICE_WRAPPER_TYPE=1 MTL_DEBUG_LAYER=1 swift test   # optional
SIMCTL_CHILD_MTL_DEBUG_LAYER=1 xcrun simctl launch booted com.tabletopcraft.ar.visionos
```

Earlier simulator checks exercised server download without restarting, a cached launch with zero downloaded bytes, 26.3 jar import, pack reload, textured foliage/glass/plants/models, fluids and animation. These are loopback simulator checks; physical-device FPS, tracking/privacy behavior and a real LAN session remain unverified. Blocks with no available pack retain the flat fallback; entity rendering, navigation clip planes and live daylight belong to later milestones.

Additional Debug-only QA arguments: `-importPack PATH`, `-mipmapsOff`, `-reloadPackAfter SECONDS`, `-hideLauncherOnOpen`, `-debugTableDistance METRES`, and `-debugEyeBlock X Y Z` (region-local coordinates). Existing `-dedicatedLayout` exercises the per-view stereo fallback. PERF reports both `upload_max_ms` and `animation_max_ms`; simulator timing is not GPU/device performance evidence.

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
