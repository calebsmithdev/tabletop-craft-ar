#if canImport(Metal)
import Foundation
import OSLog
import TabletopCore
import TabletopRender

/// Published value only: SwiftUI never reaches into mutable world or link state.
public struct SessionSnapshot: Sendable {
    public var link = "idle"
    public var connected = false
    public var rttMs = -1.0
    public var world = ""
    public var dims = SIMD3<Int>.zero
    public var loading = "Waiting for a snapshot"
    public var percent = 0
    public var lastError = ""
    public var pairCode: PairCode?
    public var paired = false
    public var tokenSaved = false
    public var wantsConnection = false
    public var pack = "Missing · download from a trusted server or import a pack"
    public var assets = ""
    public var packLoading = false
    public init() {}
}

/// One serial world owner. Neither the compositor nor MainActor applies messages.
public actor WorldSession {
    public nonisolated let scene: BatchScene
    public nonisolated let eyeProbe = EyeProbe()
    private var packWorker: PackBakeWorker?
    private var packTask: Task<PackBakeWorker.Bake, any Error>?
    private var packLoadRevision: UInt64 = 0
    private var packFailure: String?
    private var packValidationPending = false
    private var packBakeRevision: UInt64 = 0
    private var palettePreparations = 0
    #if DEBUG
    private var debugPrewarmInterrupted = false
    #endif
    private var welcomeAt: ContinuousClock.Instant?
    private var baked: BakedResourcePack?
    private var prefs = AppPrefs()
    private var packPath: String?
    private var packDescription = "Missing · download from a trusted server or import a pack"
    private let assetDirectory: URL
    private let assets: AssetSync
    private let assetsLog = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "assets")
    private var lastAssetStatus = ""
    private var wasConnected = false
    private var assetsGranted = false
    private let packLog = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "pack")
    private var world = WorldModel()
    private var assembler = SnapshotAssembler()
    private var sections: [SIMD3<Int>: SectionMesh] = [:]
    private var link: LinkClient?
    private var connectingAddress: String?
    private var pump: Task<Void, Never>?
    private var meshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var meshRunning = false
    private var workers = 3
    private var totalSections = 0
    private var completedSections: Set<SIMD3<Int>> = []
    private var meshPending: Set<SIMD3<Int>> = []
    private var areaLoaded = false
    private var snapshot = SessionSnapshot()
    private var progress = LoadProgress()
    private var health = LinkHealth()
    private var tokens: any TokenStorage
    private let linkConfiguration: LinkConfiguration
    private let transportFactory: @Sendable () -> any LinkTransport
    private var serverId: String?
    private var requestSent = false
    private let linkLog = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "link")
    private let worldLog = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "world")
    private let meshLog = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "mesh")

    public init(scene: BatchScene, tokenStorage: any TokenStorage = KeychainTokenStorage(),
                assetDirectory: URL = URL.applicationSupportDirectory.appendingPathComponent("TabletopCraft", isDirectory: true),
                linkConfiguration: LinkConfiguration = .init(),
                transportFactory: @escaping @Sendable () -> any LinkTransport = { NWLinkTransport() }) {
        self.scene = scene; tokens = tokenStorage; self.assetDirectory = assetDirectory
        #if DEBUG
        let allAssets = ProcessInfo.processInfo.arguments.contains("-downloadAllAssets")
        #else
        let allAssets = false
        #endif
        assets = AssetSync(directory: assetDirectory, allowedNames: allAssets ? AssetProtocol.names : ["pack.zip"])
        self.linkConfiguration = linkConfiguration; self.transportFactory = transportFactory
    }
    public func latest() -> SessionSnapshot {
        var value = snapshot
        if let error = scene.preparationError { value.pack = "Render error · \(error) · flat colours" }
        return value
    }

    public func configure(_ prefs: AppPrefs) {
        let remesh = self.prefs.smoothLighting != prefs.smoothLighting || self.prefs.minLight != prefs.minLight ||
            self.prefs.brightness != prefs.brightness || self.prefs.leavesInner != prefs.leavesInner
        self.prefs = prefs
        workers = max(1, min(8, prefs.meshWorkers))
        scene.setMipmaps(prefs.mipmaps)
        world.shading = BlockShading(brightness: prefs.brightness, minLight: prefs.minLight, smoothLighting: prefs.smoothLighting)
        if remesh && world.loaded { rebuildAll() }
    }

    /// Security-scoped access remains active across the background bake and copy.
    @discardableResult public func importPack(_ source: URL) async -> Bool {
        let previousManual = prefs.manualPack
        let revision = beginPackLoad()
        let candidate = PackBakeWorker()
        let states = world.palette + Array(world.movingShown.values)
        let task = Task { try await candidate.load(source, states: states) }
        packTask = task
        do {
            var value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard revision == packLoadRevision else { return false }
            try Task.checkCancellation()
            guard !task.isCancelled else { throw CancellationError() }
            if let refreshed = try await candidate.prewarm(world.palette + Array(world.movingShown.values)) { value = refreshed }
            guard revision == packLoadRevision else { return false }
            try Task.checkCancellation()
            guard !task.isCancelled else { throw CancellationError() }
            await assets.linkLost()
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            let destination = assetDirectory.appendingPathComponent("pack.zip")
            if source.standardizedFileURL != destination.standardizedFileURL {
                let temporary = assetDirectory.appendingPathComponent("pack-import.tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try? FileManager.default.removeItem(at: temporary)
                try FileManager.default.copyItem(at: source, to: temporary)
                try Data(contentsOf: temporary, options: .mappedIfSafe).write(to: destination, options: .atomic)
            }
            try quarantine.clear()
            prefs.manualPack = true
            try installPack(destination, worker: candidate, value: value)
            snapshot.packLoading = false; packTask = nil
            return true
        } catch {
            guard revision == packLoadRevision else { return false }
            prefs.manualPack = previousManual
            snapshot.packLoading = false; packTask = nil
            snapshot.pack = "Import error · \(error)"
            packLog.error("PACK import failed: \(String(describing: error), privacy: .public)")
            if !prefs.manualPack { await link?.reconnect() }
            return false
        }
    }

    private var quarantine: PackLoadQuarantine { PackLoadQuarantine(directory: assetDirectory) }
    private func beginPackLoad() -> UInt64 {
        packTask?.cancel(); packLoadRevision &+= 1
        snapshot.packLoading = true
        return packLoadRevision
    }

    public func reloadPack() async {
        guard let packPath else { return }
        do { try await loadPack(URL(fileURLWithPath: packPath)) }
        catch { snapshot.pack = "Reload error · \(error)" }
    }

    private func loadPack(_ url: URL, replacement: Bool = false) async throws {
        if !replacement, let reason = quarantine.reason {
            packFailure = "Pack disabled · \(reason) · re-download or re-import to retry"
            snapshot.pack = packFailure!
            return
        }
        let priorMarker = quarantine.reason
        let revision = beginPackLoad(), candidate = PackBakeWorker()
        try quarantine.mark("previous pack load did not finish")
        let states = world.palette + Array(world.movingShown.values)
        let task = Task { try await candidate.load(url, states: states) }
        packTask = task
        do {
            var value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard revision == packLoadRevision, !task.isCancelled else { throw CancellationError() }
            if let refreshed = try await candidate.prewarm(world.palette + Array(world.movingShown.values)) { value = refreshed }
            guard revision == packLoadRevision, !task.isCancelled else { throw CancellationError() }
            try installPack(url, worker: candidate, value: value)
            if !packValidationPending { try quarantine.clear() }
            snapshot.packLoading = false; packTask = nil
        } catch {
            if revision == packLoadRevision {
                if task.isCancelled || error is CancellationError || (error as? ResourcePackValidationError) == .cancelled {
                    if let priorMarker { try? quarantine.mark(priorMarker) } else { try? quarantine.clear() }
                    snapshot.pack = packFailure ?? packDescription
                } else {
                    let reason = String(describing: error)
                    try? quarantine.mark(reason)
                    packFailure = "Pack disabled · \(reason) · re-download or re-import to retry"
                    snapshot.pack = packFailure!
                }
                snapshot.packLoading = false; packTask = nil
            }
            throw error
        }
    }

    private func installPack(_ url: URL, worker: PackBakeWorker, value update: PackBakeWorker.Bake) throws {
        let value = update.pack
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes[.modificationDate] as? Date)?.formatted(date: .numeric, time: .shortened) ?? ""
        packWorker = worker; packBakeRevision = update.revision; baked = value; packPath = url.path; packFailure = nil
        packDescription = "pack.zip · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · \(date)"
        snapshot.pack = packDescription
        world.applyShapeOverrides(value.shapeOverrides); world.setColormaps(value.colormaps)
        if world.loaded { rebuildAll() }
        packLog.notice("PACK loaded layers=\(value.layers.count) animated=\(value.animations.count)")
    }

    private func preparePalette() async {
        guard packFailure == nil, let worker = packWorker else { return }
        let connection = connectionGeneration, revision = packLoadRevision
        snapshot.packLoading = true
        #if DEBUG
        // Deterministic simulator lifecycle probe: ordinary launches and release
        // builds never enter this path. Exercise the real disconnect/reconnect.
        if !debugPrewarmInterrupted, ProcessInfo.processInfo.arguments.contains("-debugDisconnectDuringPrewarm"), let address = link?.url {
            debugPrewarmInterrupted = true
            Task {
                try? await Task.sleep(for: .milliseconds(2))
                packLog.notice("PACK debug disconnect prewarm active=\(self.snapshot.packLoading)")
                await disconnect()
                try? await Task.sleep(for: .milliseconds(250))
                await connect(address,meshWorkers: workers)
            }
        }
        #endif
        defer { snapshot.packLoading = packTask != nil }
        do {
            guard let update = try await worker.prewarm(world.palette + Array(world.movingShown.values)),
                  !Task.isCancelled, connection == connectionGeneration,
                  revision == packLoadRevision, packWorker === worker, update.revision > packBakeRevision else { return }
            let value = update.pack
            packBakeRevision = update.revision
            baked = value
            world.applyShapeOverrides(value.shapeOverrides); world.setColormaps(value.colormaps)
            // Closes the GPU publication gate before any mesh can reference new layers.
            markGPUPreparation()
            scene.updatePack(value, generation: generation)
        } catch {
            guard revision == packLoadRevision, packWorker === worker else { return }
            // Prewarm does not change the marker before suspension. Leaving it
            // untouched preserves any prior GPU validation marker as well.
            if Task.isCancelled || error is CancellationError || (error as? ResourcePackValidationError) == .cancelled { return }
            try? quarantine.mark(String(describing: error))
            packFailure = "Pack disabled · \(error) · re-download or re-import to retry"
            snapshot.pack = packFailure!
            packLog.error("PACK prewarm failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func markGPUPreparation() {
        guard baked != nil, packFailure == nil else { return }
        do {
            try quarantine.mark("previous GPU pack preparation did not finish")
            packValidationPending = true
        } catch {
            packLog.error("PACK could not persist load marker: \(String(describing: error), privacy: .public)")
        }
    }

    private func finishGPUPreparation() {
        guard !scene.packPreparationPending else { return }
        if let error = scene.preparationError, baked != nil {
            packValidationPending = false
            try? quarantine.mark(error)
            packFailure = "Render error · \(error) · flat colours"
            snapshot.pack = packFailure!
            // Texture-derived vertex colours are white; rebuild them from the
            // classic source once so GPU allocation failure really is flat fallback.
            baked = nil
            world.applyShapeOverrides([:])
            if world.loaded { rebuildAll() }
        } else if packValidationPending {
            packValidationPending = false
            // This upload may precede a newer CPU validation failure. Only a
            // successful replacement/import may clear that newer quarantine.
            if packFailure == nil { try? quarantine.clear() }
        }
    }

    private func rebuildAll() {
        generation &+= 1
        sections.removeAll()
        let n = world.sectionCount
        world.dirtySections.removeAll()
        for x in 0..<n.x { for y in 0..<n.y { for z in 0..<n.z {
            world.dirtySections.insert(SIMD3(x,y,z))
        } } }
        totalSections = world.dirtySections.count; completedSections = []; areaLoaded = false
        progress.begin(totalSections)
        markGPUPreparation()
        scene.beginGeneration(generation, pack: baked)
        publishProbe()
        scheduleMeshes()
    }

    private var blockSize: Float { max(0.002, min(0.1, prefs.blockSizeM ?? (0.5 / Float(max(1, max(world.dims.x, world.dims.z)))))) }
    private var blockCenter: SIMD3<Float> { SIMD3(Float(world.dims.x)/2, 0, Float(world.dims.z)/2) }
    private func publishProbe() { eyeProbe.publish(world: world, blockSize: blockSize, center: blockCenter, generation: generation) }

    public func connect(_ address: String, meshWorkers: Int = 3) async {
        // Reserve the address before the first suspension, so repeated scene or
        // button events cannot tear down an in-progress connection.
        if connectingAddress == address { return }
        if let current = link, current.url == address {
            let state = await current.state
            if link === current, state != .fatal, state != .stopped { return }
        }
        connectingAddress = address
        connectionGeneration &+= 1
        let id = connectionGeneration
        pump?.cancel(); pump = nil
        let previous = link
        link = nil
        await previous?.stop(reason: "server changed")
        await assets.linkLost(); wasConnected = false; assetsGranted = false; welcomeAt = nil
        guard id == connectionGeneration else { return }
        generation &+= 1
        scene.reset(generation: generation)
        world = WorldModel(); sections = [:]; assembler = SnapshotAssembler()
        snapshot = SessionSnapshot(); snapshot.wantsConnection = true; snapshot.pack = packDescription
        world.shading = BlockShading(brightness: prefs.brightness, minLight: prefs.minLight, smoothLighting: prefs.smoothLighting)
        if packWorker == nil {
            let cached = assetDirectory.appendingPathComponent("pack.zip")
            if FileManager.default.fileExists(atPath: cached.path) {
                do { try await loadPack(cached) }
                catch { snapshot.pack = packFailure ?? "Pack error · \(error)"; packLog.error("PACK cached load failed: \(String(describing: error), privacy: .public)") }
            }
        }
        guard id == connectionGeneration else { return }
        health.newServer(Date().timeIntervalSince1970)
        workers = max(1, min(8, meshWorkers))
        serverId = nil; requestSent = false
        let token: String?
        do { token = try tokens.tokenFor(address, nil) }
        catch { snapshot.lastError = "Could not read pairing: \(error)"; token = nil }
        snapshot.tokenSaved = token != nil
        let client = LinkClient(url: address, deviceToken: token, deviceName: "Apple Vision Pro",
                                configuration: linkConfiguration, transportFactory: transportFactory,
                                binary: { [assets] data in await assets.receiveBinary(data) })
        link = client
        connectingAddress = nil
        await client.start()
        guard id == connectionGeneration else { return }
        pump = Task { await drive(client, id: id) }
        linkLog.notice("LINK start \(address, privacy: .public)")
    }

    public func disconnect(background: Bool = false) async {
        connectingAddress = nil
        packTask?.cancel()
        connectionGeneration &+= 1
        pump?.cancel(); pump = nil
        let previous = link
        link = nil
        snapshot.wantsConnection = background && snapshot.wantsConnection
        snapshot.connected = false; snapshot.link = background ? "paused" : "stopped"
        snapshot.rttMs = -1
        await previous?.stop(reason: background ? "app background" : "disconnected")
        await assets.linkLost(); wasConnected = false; assetsGranted = false; welcomeAt = nil
        linkLog.notice("LINK bye \(background ? "app background" : "disconnected", privacy: .public)")
    }

    public func useServerPack() async {
        prefs.manualPack = false
        if quarantine.reason != nil { await assets.forceDownload("pack.zip") }
        await link?.reconnect()
    }

    public func renewPairing() async {
        guard let link else { return }
        requestSent = true
        await link.sendPairing(PairingProtocol.request("Apple Vision Pro"))
    }

    private func drive(_ client: LinkClient, id: UInt64) async {
        var previousStatus = ""
        while !Task.isCancelled, id == connectionGeneration {
            if let rejected = await client.takeRejectedDeviceToken() {
                guard id == connectionGeneration else { return }
                do {
                    if try tokens.find(client.url, serverId)?.token == rejected {
                        try tokens.forget(client.url, serverId)
                        snapshot.tokenSaved = false
                        snapshot.paired = false
                    }
                } catch { storageFailed(error) }
            }
            let messages = await client.drain()
            guard id == connectionGeneration else { return }
            for message in messages {
                await apply(message, client: client, connection: id)
                guard id == connectionGeneration else { return }
            }
            let connected = await client.connected
            let status = await client.status
            let state = await client.state
            let rtt = await client.rttMs
            guard id == connectionGeneration else { return }
            if wasConnected && !connected { await assets.linkLost(); assetsGranted = false; welcomeAt = nil }
            wasConnected = connected
            if connected {
                for request in await assets.drainRequests() { await client.send(request) }
                for completion in await assets.drainCompletions() where completion.name == "pack.zip" {
                    do { try await loadPack(completion.url, replacement: true) }
                    catch { snapshot.pack = packFailure ?? "Pack error · \(error)"; packLog.error("PACK downloaded load failed: \(String(describing: error), privacy: .public)") }
                }
            }
            let assetStatus = await assets.snapshot()
            guard id == connectionGeneration else { return }
            let inOfferGrace = welcomeAt.map { assetsGranted && $0.duration(to: .now) < .seconds(2) } ?? true
            let waitingForOffer = !assetStatus.offered && inOfferGrace
            snapshot.assets = prefs.manualPack ? "Manual pack selected" :
                (waitingForOffer ? "Waiting for asset offer" : assetStatus.status)
            if let item = assetStatus.items.first(where: { $0.offer.name == "pack.zip" }), !prefs.manualPack {
                if item.state == .downloading || item.state == .waiting || item.state == .checking || item.state == .verifying {
                    snapshot.pack = "Downloading pack.zip · \(item.offer.size > 0 ? item.received * 100 / item.offer.size : 0) %"
                } else if item.state == .failed { snapshot.pack = "Download error · \(item.note)" }
                else { snapshot.pack = packFailure ?? packDescription }
            }
            if snapshot.assets != lastAssetStatus {
                lastAssetStatus = snapshot.assets
                assetsLog.notice("ASSETS \(self.snapshot.assets, privacy: .public) bytes=\(assetStatus.bytesReceived)")
            }
            snapshot.connected = connected
            snapshot.link = connected ? "up" : state.rawValue + " · " + status
            snapshot.rttMs = rtt
            health.update(connected, Date().timeIntervalSince1970)
            if status != previousStatus {
                previousStatus = status
                linkLog.notice("LINK \(status, privacy: .public)")
            }
            if state == .fatal { snapshot.lastError = status }
            if let code = snapshot.pairCode, !code.live(Date().timeIntervalSince1970) {
                snapshot.pairCode = nil
                if code.required { await renewPairing() }
            }
            finishGPUPreparation()
            publishProbe()
            scheduleMeshes()
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
    }

    private func apply(_ m: JSONObject, client: LinkClient, connection: UInt64) async {
        do {
            if ["region_changed", "region_info", "error"].contains(m.s("type") ?? ""),
               let limits = m.o("limits"), limits["max_blocks"] != nil {
                assembler.maxBlocks = RegionLimits.from(limits).maxBlocks
            }
            switch m.s("type") {
            case "assets":
                guard assetsGranted else { return }
                var offer = m
                if prefs.manualPack { offer["files"] = .array((m.a("files") ?? []).filter { $0.objectValue?.s("name") != "pack.zip" }) }
                await assets.acceptOffer(offer)
            case "welcome":
                let welcome = try Welcome.from(m)
                assetsGranted = welcome.caps.contains("assets_v1")
                welcomeAt = .now
                assembler.maxBlocks = m.o("limits")?["max_blocks"] == nil ? nil : welcome.limits.maxBlocks
                snapshot.world = welcome.world; snapshot.dims = welcome.dims
                snapshot.paired = PairingWelcome.from(m).paired
                serverId = welcome.serverId
                requestSent = false
                do { try tokens.seen(client.url, serverId) } catch { storageFailed(error) }
                let pairing = PairingWelcome.from(m)
                if pairing.paired { snapshot.pairCode = nil }
                else if pairing.supported {
                    let sentToken = await client.deviceToken
                    guard connection == connectionGeneration else { return }
                    // A newly discovered URL can refer to a known server. Do not
                    // discard its credential unless this connection presented it
                    // or the server explicitly rejected it (Quest pairing rule).
                    if pairing.tokenRejected || sentToken?.isEmpty == false {
                        do { try tokens.forget(client.url, serverId) } catch { storageFailed(error) }
                    }
                    snapshot.tokenSaved = false
                    await client.setDeviceToken(nil)
                    guard connection == connectionGeneration else { return }
                    if !requestSent { await renewPairing() }
                }
            case "pair_code":
                snapshot.pairCode = PairCode.from(m, Date().timeIntervalSince1970)
                snapshot.paired = false
                if snapshot.pairCode?.tokenRejected == true {
                    do { try tokens.forget(client.url, serverId) } catch { storageFailed(error) }
                    snapshot.tokenSaved = false
                }
                linkLog.notice("LINK PAIR code shown")
            case "paired":
                guard let token = m.s("token"), !token.isEmpty else { return }
                let sameConnection = snapshot.pairCode?.required == true
                let sid = m.s("server_id") ?? serverId
                do {
                    try tokens.save(sid, client.url, token, m.s("device"), m.s("name"), Int64(Date().timeIntervalSince1970 * 1000))
                    snapshot.tokenSaved = true
                    linkLog.notice("LINK PAIR token stored in Keychain")
                } catch { snapshot.tokenSaved = false; storageFailed(error) }
                serverId = sid; snapshot.pairCode = nil; snapshot.paired = true
                await client.setDeviceToken(token)
                guard connection == connectionGeneration else { return }
                if !sameConnection { await client.reconnect() }
            case "chunk_snapshot":
                try assembler.offer(m, world)
                if let result = assembler.tryTake() {
                    if let error = result.error {
                        snapshot.lastError = error
                        await client.send(["type": "error", "code": "bad_snapshot", "snapshot_id": .number(Double(result.snapshotId)), "message": .string(error)])
                    } else if let value = result.snapshot {
                        // A prior mesh round can finish while prewarming suspends.
                        // Keep its completion from consuming this world's dirty set.
                        palettePreparations += 1
                        defer { palettePreparations -= 1; scheduleMeshes() }
                        generation &+= 1
                        world.load(value); sections.removeAll()
                        totalSections = world.dirtySections.count; completedSections = []; areaLoaded = false
                        progress.begin(totalSections)
                        snapshot.percent = 0; snapshot.loading = "Loading area 0 %"
                        snapshot.world = world.world; snapshot.dims = world.dims
                        await preparePalette()
                        guard connection == connectionGeneration else { return }
                        markGPUPreparation()
                        scene.beginGeneration(generation, pack: baked)
                        publishProbe()
                        worldLog.notice("AREA_RECEIVED snapshot=\(value.snapshotId) dims=\(String(describing: value.dims), privacy: .public) decode_ms=\(result.ms)")
                    }
                } else {
                    snapshot.loading = "Receiving snapshot · \(assembler.partsWaiting) parts"
                }
            case "block_update":
                palettePreparations += 1
                defer { palettePreparations -= 1; scheduleMeshes() }
                // Linearize readiness before decoding/applying edits: the GPU
                // worker must not commit a staged snapshot during this work.
                if m.i("snapshot_id", -2) == world.snapshotId,
                   scene.invalidateCompletion(generation) { areaLoaded = false }
                if world.applyBlockUpdate(m) {
                    await preparePalette()
                    guard connection == connectionGeneration else { return }
                    publishProbe()
                    worldLog.debug("WORLD block_update dirty=\(self.world.dirtySections.count)")
                }
                // Empty/ignored updates add no meshing work. Restore readiness
                // immediately rather than leaving an otherwise finished stage stuck.
                if completedSections.count == totalSections, meshPending.isEmpty,
                   world.dirtySections.isEmpty, !areaLoaded {
                    areaLoaded = true
                    scene.completeGeneration(generation)
                }
            case "error":
                if await !assets.receiveError(m) { snapshot.lastError = m.s("message") ?? m.s("code") ?? "Server error" }
            default: break
            }
        } catch { snapshot.lastError = String(describing: error) }
    }

    private func storageFailed(_ error: any Error) {
        snapshot.lastError = "Pairing storage: \(error)"
        linkLog.error("LINK pairing storage unavailable: \(String(describing: error), privacy: .public)")
    }

    private func scheduleMeshes() {
        guard palettePreparations == 0, !meshRunning, world.loaded, !world.dirtySections.isEmpty else { return }
        let keys = world.dirtySections.sorted { a, b in
            if a.y != b.y { return a.y > b.y }
            if a.x != b.x { return a.x < b.x }
            return a.z < b.z
        }
        world.dirtySections.removeAll()
        let immutableWorld = world, epoch = generation, count = workers, pack = baked, leaves = prefs.leavesInner
        meshRunning = true
        meshPending = Set(keys)
        meshTask = Task {
            await withTaskGroup(of: MeshedSection.self) { group in
                var next = 0
                for _ in 0..<min(count, keys.count) {
                    let key = keys[next]; next += 1
                    group.addTask { Self.mesh(immutableWorld, key, pack: pack, leavesInner: leaves) }
                }
                for await result in group {
                    guard epoch == generation else { group.cancelAll(); break }
                    accept(result, epoch: epoch)
                    if next < keys.count {
                        let key = keys[next]; next += 1
                        group.addTask { Self.mesh(immutableWorld, key, pack: pack, leavesInner: leaves) }
                    }
                }
            }
            meshRunning = false; meshTask = nil
            scheduleMeshes()
        }
    }

    private struct MeshedSection: Sendable {
        let key: SIMD3<Int>
        let mesh: SectionMesh?
        let ms: Double
    }
    private nonisolated static func mesh(_ world: WorldModel, _ key: SIMD3<Int>, pack: BakedResourcePack?, leavesInner: Bool) -> MeshedSection {
        let start = Date.timeIntervalSinceReferenceDate
        var data = MeshData()
        if let pack {
            GreedyMesher.build(world, key, pack, &data, leavesInner: leavesInner)
            GreedyMesher.buildSpecials(world, key, pack, &data)
        } else {
            GreedyMesher.build(world, key, &data)
            GreedyMesher.buildSpecials(world, key, &data)
        }
        return MeshedSection(key: key, mesh: SectionMesh.from(data, key, solidLayers: pack?.solidLayers ?? []), ms: (Date.timeIntervalSinceReferenceDate-start)*1000)
    }
    private func accept(_ result: MeshedSection, epoch: UInt64) {
        sections[result.key] = result.mesh
        completedSections.insert(result.key)
        meshPending.remove(result.key)
        let layout = BatchLayout(world.origin, world.dims)
        let key = layout.keyOf(result.key)
        // Assemble only once every section in this batch has finished its current
        // round. A later edit dirties it again; the next round replaces this batch.
        let pendingCount = max(0, totalSections-completedSections.count)
        snapshot.percent = totalSections > 0 ? min(100, completedSections.count*100/totalSections) : 100
        snapshot.loading = progress.text(pendingCount) ?? (pendingCount == 0 ? "Area loaded" : "Loading area \(snapshot.percent) %")
        guard !layout.sectionsOf(key).contains(where: { meshPending.contains($0) }) else { return }
        let parts = layout.sectionsOf(key).compactMap { section -> (mesh: SectionMesh, offset: SIMD3<Float>)? in
            guard let mesh = sections[section] else { return nil }
            return (mesh, layout.offset(section, key, layout.sy))
        }
        let data = BatchData.assemble(parts)
        let size = blockSize
        let center = blockCenter
        scene.publish(BatchUpload(generation: epoch, key: key, data: data,
                                 position: layout.position(key, layout.sy), blockSize: size, center: center,
                                 cellOrigin: world.origin &+ SIMD3<Int>(layout.position(key, layout.sy))))
        if pendingCount == 0 && meshPending.isEmpty && world.dirtySections.isEmpty && !areaLoaded {
            areaLoaded = true
            scene.completeGeneration(epoch)
            worldLog.notice("AREA_LOADED snapshot=\(self.world.snapshotId) batches=\(layout.allKeys().count) sections=\(self.sections.count) block_size_m=\(size)")
        }
        meshLog.debug("MESH section=\(String(describing: result.key), privacy: .public) ms=\(result.ms)")
    }
}
#endif
