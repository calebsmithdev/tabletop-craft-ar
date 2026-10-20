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
    public init() {}
}

/// One serial world owner. Neither the compositor nor MainActor applies messages.
public actor WorldSession {
    public nonisolated let scene: BatchScene
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
                linkConfiguration: LinkConfiguration = .init(),
                transportFactory: @escaping @Sendable () -> any LinkTransport = { NWLinkTransport() }) {
        self.scene = scene; tokens = tokenStorage
        self.linkConfiguration = linkConfiguration; self.transportFactory = transportFactory
    }
    public func latest() -> SessionSnapshot { snapshot }

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
        guard id == connectionGeneration else { return }
        generation &+= 1
        scene.reset(generation: generation)
        world = WorldModel(); sections = [:]; assembler = SnapshotAssembler()
        snapshot = SessionSnapshot(); snapshot.wantsConnection = true
        health.newServer(Date().timeIntervalSince1970)
        workers = max(1, min(8, meshWorkers))
        serverId = nil; requestSent = false
        let token: String?
        do { token = try tokens.tokenFor(address, nil) }
        catch { snapshot.lastError = "Could not read pairing: \(error)"; token = nil }
        snapshot.tokenSaved = token != nil
        let client = LinkClient(url: address, deviceToken: token, deviceName: "Apple Vision Pro",
                                configuration: linkConfiguration, transportFactory: transportFactory)
        link = client
        connectingAddress = nil
        await client.start()
        guard id == connectionGeneration else { return }
        pump = Task { await drive(client, id: id) }
        linkLog.notice("LINK start \(address, privacy: .public)")
    }

    public func disconnect(background: Bool = false) async {
        connectingAddress = nil
        connectionGeneration &+= 1
        pump?.cancel(); pump = nil
        let previous = link
        link = nil
        snapshot.wantsConnection = background && snapshot.wantsConnection
        snapshot.connected = false; snapshot.link = background ? "paused" : "stopped"
        snapshot.rttMs = -1
        await previous?.stop(reason: background ? "app background" : "disconnected")
        linkLog.notice("LINK bye \(background ? "app background" : "disconnected", privacy: .public)")
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
            case "welcome":
                let welcome = try Welcome.from(m)
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
                        generation &+= 1
                        world.load(value); sections.removeAll()
                        scene.beginGeneration(generation)
                        snapshot.world = world.world; snapshot.dims = world.dims
                        totalSections = world.dirtySections.count; completedSections = []; areaLoaded = false
                        progress.begin(totalSections)
                        snapshot.percent = 0; snapshot.loading = "Loading area 0 %"
                        worldLog.notice("AREA_RECEIVED snapshot=\(value.snapshotId) dims=\(String(describing: value.dims), privacy: .public) decode_ms=\(result.ms)")
                    }
                } else {
                    snapshot.loading = "Receiving snapshot · \(assembler.partsWaiting) parts"
                }
            case "block_update":
                // Linearize readiness before decoding/applying edits: the GPU
                // worker must not commit a staged snapshot during this work.
                if m.i("snapshot_id", -2) == world.snapshotId,
                   scene.invalidateCompletion(generation) { areaLoaded = false }
                if world.applyBlockUpdate(m) {
                    worldLog.debug("WORLD block_update dirty=\(self.world.dirtySections.count)")
                }
                // Empty/ignored updates add no meshing work. Restore readiness
                // immediately rather than leaving an otherwise finished stage stuck.
                if completedSections.count == totalSections, meshPending.isEmpty,
                   world.dirtySections.isEmpty, !areaLoaded {
                    areaLoaded = true
                    scene.completeGeneration(generation)
                }
            case "error": snapshot.lastError = m.s("message") ?? m.s("code") ?? "Server error"
            default: break
            }
        } catch { snapshot.lastError = String(describing: error) }
    }

    private func storageFailed(_ error: any Error) {
        snapshot.lastError = "Pairing storage: \(error)"
        linkLog.error("LINK pairing storage unavailable: \(String(describing: error), privacy: .public)")
    }

    private func scheduleMeshes() {
        guard !meshRunning, world.loaded, !world.dirtySections.isEmpty else { return }
        let keys = world.dirtySections.sorted { a, b in
            if a.y != b.y { return a.y > b.y }
            if a.x != b.x { return a.x < b.x }
            return a.z < b.z
        }
        world.dirtySections.removeAll()
        let immutableWorld = world, epoch = generation, count = workers
        meshRunning = true
        meshPending = Set(keys)
        meshTask = Task {
            await withTaskGroup(of: MeshedSection.self) { group in
                var next = 0
                for _ in 0..<min(count, keys.count) {
                    let key = keys[next]; next += 1
                    group.addTask { Self.mesh(immutableWorld, key) }
                }
                for await result in group {
                    guard epoch == generation else { group.cancelAll(); break }
                    accept(result, epoch: epoch)
                    if next < keys.count {
                        let key = keys[next]; next += 1
                        group.addTask { Self.mesh(immutableWorld, key) }
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
    private nonisolated static func mesh(_ world: WorldModel, _ key: SIMD3<Int>) -> MeshedSection {
        let start = Date.timeIntervalSinceReferenceDate
        var data = MeshData()
        GreedyMesher.build(world, key, &data)
        GreedyMesher.buildSpecials(world, key, &data)
        return MeshedSection(key: key, mesh: SectionMesh.from(data, key), ms: (Date.timeIntervalSinceReferenceDate-start)*1000)
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
        let size = max(0.002, min(0.1, 0.5 / Float(max(world.dims.x, world.dims.z))))
        let center = SIMD3<Float>(Float(world.dims.x)/2, 0, Float(world.dims.z)/2)
        scene.publish(BatchUpload(generation: epoch, key: key, data: data,
                                 position: layout.position(key, layout.sy), blockSize: size, center: center))
        if pendingCount == 0 && meshPending.isEmpty && world.dirtySections.isEmpty && !areaLoaded {
            areaLoaded = true
            scene.completeGeneration(epoch)
            worldLog.notice("AREA_LOADED snapshot=\(self.world.snapshotId) batches=\(layout.allKeys().count) sections=\(self.sections.count) block_size_m=\(size)")
        }
        meshLog.debug("MESH section=\(String(describing: result.key), privacy: .public) ms=\(result.ms)")
    }
}
#endif
