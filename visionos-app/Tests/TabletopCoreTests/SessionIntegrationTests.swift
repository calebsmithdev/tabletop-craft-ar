import Foundation
import Metal
import Synchronization
import Testing
@testable import TabletopCore
@testable import TabletopRender
import TabletopSpatial

private func sessionEventually(_ label: String = "session timed out", _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw JsonError(label) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor SessionTransport: LinkTransport {
    var incoming: [LinkFrame] = []
    var outgoing: [JSONObject] = []
    var cancelled = false
    func connect(url: URL) {}
    func send(_ frame: LinkFrame) throws {
        if case .text(let text) = frame, let value = try Json.parse(text).objectValue { outgoing.append(value) }
    }
    func receive() async throws -> LinkFrame {
        while incoming.isEmpty && !cancelled { try await Task.sleep(for: .milliseconds(5)) }
        guard !cancelled else { throw CancellationError() }
        return incoming.removeFirst()
    }
    func cancel() { cancelled = true }
    func append(_ message: JSONObject) throws { incoming.append(.text(try Json.stringify(message))) }
    func revoke() { incoming.append(.close(code: 4003, reason: "revoked")) }
    func messages() -> [JSONObject] { outgoing }
}

private final class SessionTransports: Sendable {
    let list: Mutex<[SessionTransport]>
    init(_ list: [SessionTransport]) { self.list = Mutex(list) }
    func next() -> any LinkTransport { list.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }
}

private final class SessionTokens: TokenStorage {
    private let store = Mutex(PairingStore())
    func find(_ url: String?, _ sid: String?) -> PairingEntry? { store.withLock { $0.find(url, sid) } }
    func save(_ sid: String?, _ url: String?, _ token: String, _ device: String?, _ name: String?, _ now: Int64) {
        store.withLock { $0.save(sid, url, token, device, name, now) }
    }
    func seen(_ url: String?, _ sid: String?) -> Bool { store.withLock { $0.seen(url, sid) } }
    func forget(_ url: String?, _ sid: String?) -> Bool { store.withLock { $0.forget(url, sid) } }
}

private struct UnavailableTokens: TokenStorage {
    func find(_ url: String?, _ sid: String?) throws -> PairingEntry? { throw JsonError("storage unavailable") }
    mutating func save(_ sid: String?, _ url: String?, _ token: String, _ device: String?, _ name: String?, _ now: Int64) throws { throw JsonError("storage unavailable") }
    mutating func seen(_ url: String?, _ sid: String?) throws -> Bool { throw JsonError("storage unavailable") }
    mutating func forget(_ url: String?, _ sid: String?) throws -> Bool { throw JsonError("storage unavailable") }
}

private func sessionWelcome(paired: Bool) -> JSONObject {
    ["type": "welcome", "protocol": 1, "world": "world", "server_id": "test-server",
     "region": ["origin": [0, 0, 0], "dims": [1, 1, 1]],
     "pairing": ["paired": .bool(paired), "required": true], "caps": ["pair_v1"]]
}
private func sessionConfig() -> LinkConfiguration {
    var c = LinkConfiguration(); c.backoffInitialSeconds = 0.01; c.shutdownSeconds = 0.02
    return c
}

@Suite struct SessionIntegrationTests {
    @Test func disconnectDuringPalettePrewarmPreservesPackAcrossReconnectAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var entries = try atlasFluidEntries()
        let element = ##"{"from":[0,0,0],"to":[16,16,16],"faces":{"west":{"texture":"#all"},"east":{"texture":"#all"},"up":{"texture":"#all"}}}"##
        let model = "{\"textures\":{\"all\":\"test:water_still\"},\"elements\":[" + Array(repeating: element,count: 10_000).joined(separator: ",") + "]}"
        entries.append(("assets/test/models/slow.json",Array(model.utf8),true))
        for index in 0..<3 {
            entries.append(("assets/test/blockstates/slow\(index).json",Array(#"{"variants":{"":{"model":"test:slow"}}}"#.utf8),false))
        }
        let source = try atlasZip(entries)
        defer { try? FileManager.default.removeItem(at: source) }
        let marker = directory.appendingPathComponent("pack-load-failure.txt")
        let transports = (0..<4).map { _ in SessionTransport() }, factory = SessionTransports(transports)
        let scene = BatchScene()
        let mailbox = try scene.attach(device: #require(MTLCreateSystemDefaultDevice()))
        let session = WorldSession(scene: scene,tokenStorage: SessionTokens(),assetDirectory: directory,
            linkConfiguration: sessionConfig(),transportFactory: { factory.next() })
        #expect(await session.importPack(source))
        let address = "ws://example.test:8765/tabletop"
        func snapshot(_ state: String) -> JSONObject {
            ["type":"chunk_snapshot","snapshot_id":1,"world":"world","origin":[0,0,0],"dims":[1,1,1],
             "order":"yzx","encoding":"rle_palette_v1","palette":[.string(state)],"data":[0,1]]
        }
        for index in 0..<3 {
            let priorMarker = index == 0 ? nil : "prior GPU validation marker"
            if let priorMarker { try priorMarker.write(to: marker,atomically: true,encoding: .utf8) }
            try await transports[index].append(sessionWelcome(paired: true))
            try await transports[index].append(snapshot("test:slow\(index)"))
            await session.connect(address)
            try await sessionEventually("palette prewarm did not start") { await session.latest().packLoading }
            await session.disconnect(background: index == 1)
            try await sessionEventually("cancelled palette prewarm did not finish") { await !session.latest().packLoading }
            #expect(await !session.latest().pack.contains("disabled"))
            #expect((try? String(contentsOf: marker,encoding: .utf8)) == priorMarker)
        }
        try await transports[3].append(sessionWelcome(paired: true))
        try await transports[3].append(snapshot("test:slow2"))
        await session.connect(address)
        try await sessionEventually { await session.latest().percent == 100 && !scene.packPreparationPending }
        try await sessionEventually { !FileManager.default.fileExists(atPath: marker.path) }
        #expect(scene.snapshot().batches.values.contains { $0.data.verts.contains { $0.uv.z >= 0 } })
        #expect(await !session.latest().pack.contains("disabled"))
        await session.disconnect()
        let relaunchedScene = BatchScene(), relaunchedTransport = SessionTransport()
        let relaunchedMailbox = try relaunchedScene.attach(device: #require(MTLCreateSystemDefaultDevice()))
        try await relaunchedTransport.append(sessionWelcome(paired: true))
        try await relaunchedTransport.append(snapshot("test:slow0"))
        let relaunched = WorldSession(scene: relaunchedScene,tokenStorage: SessionTokens(),assetDirectory: directory,
            linkConfiguration: sessionConfig(),transportFactory: { relaunchedTransport })
        await relaunched.connect(address)
        try await sessionEventually { await relaunched.latest().percent == 100 && !relaunchedScene.packPreparationPending }
        try await sessionEventually { !FileManager.default.fileExists(atPath: marker.path) }
        #expect(await relaunched.latest().pack.contains("pack.zip"))
        #expect(relaunchedScene.snapshot().batches.values.contains { $0.data.verts.contains { $0.uv.z >= 0 } })
        await relaunched.disconnect()
        withExtendedLifetime((mailbox,relaunchedMailbox)) {}
    }

    @Test func refreshedRegionLimitsAllowLargerSnapshotWithoutReconnect() async throws {
        for type in ["region_changed", "region_info", "error"] {
            let transport = SessionTransport(), scene = BatchScene()
            var welcome = sessionWelcome(paired: true); welcome["limits"] = ["max_blocks": 1]
            try await transport.append(welcome)
            let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), linkConfiguration: sessionConfig(), transportFactory: { transport })
            await session.connect("ws://example.test:8765/tabletop")
            try await sessionEventually { await session.latest().connected }
            let larger: JSONObject = ["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0], "dims": [3,1,1],
                                     "order": "yzx", "encoding": "rle_palette_v1", "palette": ["minecraft:stone"], "data": [0,3]]
            try await transport.append(larger)
            try await sessionEventually { await transport.messages().contains { $0.s("code") == "bad_snapshot" } }
            try await transport.append(["type": .string(type), "limits": ["max_blocks": 3]])
            try await transport.append(larger)
            try await sessionEventually { scene.snapshot().batches.count == 1 }
            #expect(await session.latest().dims == [3,1,1])
            // A later message with partial limits must preserve max_blocks.
            try await transport.append(["type": .string(type), "limits": ["max_bytes": 1024]])
            try await transport.append(larger)
            try await sessionEventually { scene.snapshot().generation >= 3 }
            // Even a server advertising Int.max cannot raise the hard ceiling.
            try await transport.append(["type": .string(type), "limits": ["max_blocks": .number(Double(Int.max / 2))]])
            var oversized = larger; oversized["dims"] = [353,384,352]
            try await transport.append(oversized)
            try await sessionEventually { await transport.messages().filter { $0.s("code") == "bad_snapshot" }.count == 2 }
            #expect(await session.latest().connected)
            await session.disconnect()
        }
    }

    @Test func connectingToSameAddressKeepsHealthyTransport() async throws {
        let transport = SessionTransport(), scene = BatchScene()
        try await transport.append(sessionWelcome(paired: true))
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), linkConfiguration: sessionConfig(), transportFactory: { transport })
        let address = "ws://example.test:8765/tabletop"
        await session.connect(address)
        // Repeated connection while connecting and after welcome is a no-op.
        await session.connect(address)
        try await sessionEventually { await session.latest().connected }
        let generation = scene.snapshot().generation
        await session.connect(address)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.messages().filter { $0.s("type") == "hello" }.count == 1)
        #expect(await transport.messages().allSatisfy { $0.s("type") != "bye" })
        #expect(scene.snapshot().generation == generation)
        #expect(await session.latest().connected)
        await session.disconnect()
    }

    @Test func advertisedSnapshotLimitSendsBadSnapshotAndRecovers() async throws {
        let transport = SessionTransport(), scene = BatchScene()
        var welcome = sessionWelcome(paired: true)
        welcome["limits"] = ["max_blocks": 8]
        try await transport.append(welcome)
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0], "dims": [11,1,1],
                                    "order": "yzx", "encoding": "rle_palette_v1", "palette": ["minecraft:stone"], "data": [0,11]])
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), linkConfiguration: sessionConfig(), transportFactory: { transport })
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { await transport.messages().contains { $0.s("code") == "bad_snapshot" } }
        #expect(scene.snapshot().batches.isEmpty)
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 2, "world": "world", "origin": [0,0,0], "dims": [1,1,1],
                                    "order": "yzx", "encoding": "rle_palette_v1", "palette": ["minecraft:stone"], "data": [0,1]])
        try await sessionEventually { !scene.snapshot().batches.isEmpty }
        #expect(await session.latest().connected)
        await session.disconnect()
    }

    @Test func emptyUpdateDoesNotStrandCompletedStagingGeneration() async throws {
        let transport = SessionTransport(), scene = BatchScene()
        try await transport.append(sessionWelcome(paired: true))
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0], "dims": [1,1,1],
                                    "order": "yzx", "encoding": "rle_palette_v1", "palette": ["minecraft:stone"], "data": [0,1]])
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), linkConfiguration: sessionConfig(), transportFactory: { transport })
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { await session.latest().percent == 100 }
        // A matching update can be accepted even when every change is ignored.
        try await transport.append(["type": "block_update", "snapshot_id": 1, "changes": []])
        try await transport.append(["type": "block_update", "snapshot_id": 1, "changes": [[99,0,0,0]]])
        try await Task.sleep(for: .milliseconds(100))
        let target = scene.snapshot().generation
        let device = try #require(MTLCreateSystemDefaultDevice())
        let mailbox = try scene.attach(device: device)
        var visible: UInt64?
        var drawnCount = 0
        try await sessionEventually {
            if let update = mailbox.next(generation: visible) {
                switch update {
                case .replace(let next, let batches): visible = next; drawnCount = batches.count
                case .batch: drawnCount += 1
                }
            }
            return visible == target && drawnCount == 1
        }
        #expect(await session.latest().connected)
        await session.disconnect()
    }

    @Test func revokedPairingReplacesCredentialAndSurvivesNewClient() async throws {
        let address = "ws://example.test:8765/tabletop", tokens = SessionTokens()
        tokens.save("test-server", address, "old-test-token", nil, nil, 0)
        let first = SessionTransport(), second = SessionTransport(), third = SessionTransport()
        let transports = SessionTransports([first, second, third])
        let session = WorldSession(scene: BatchScene(), tokenStorage: tokens, linkConfiguration: sessionConfig(), transportFactory: { transports.next() })
        try await first.append(sessionWelcome(paired: true))
        await session.connect(address)
        try await sessionEventually { await session.latest().paired }
        await first.revoke()
        try await second.append(["type": "pair_code", "code": "123456", "required": true])
        try await sessionEventually { await session.latest().pairCode != nil }
        #expect(await session.latest().paired == false)
        #expect(tokens.find(address, nil) == nil)
        try await second.append(["type": "paired", "token": "replacement-test-token", "server_id": "test-server"])
        try await second.append(sessionWelcome(paired: true))
        try await sessionEventually { let state = await session.latest(); return state.paired && state.tokenSaved }
        #expect(tokens.find(address, nil)?.token == "replacement-test-token")
        await session.disconnect()
        try await third.append(sessionWelcome(paired: true))
        await session.connect(address)
        try await sessionEventually { await third.messages().contains { $0.s("type") == "hello" } }
        #expect(await third.messages().first?.s("device_token") == "replacement-test-token")
        await session.disconnect()
    }

    @Test func newAddressDoesNotDeleteAnUnpresentedServerCredential() async throws {
        let tokens = SessionTokens(), transport = SessionTransport()
        tokens.save("test-server", "ws://old.example.test:8765/tabletop", "saved-test-token", nil, nil, 0)
        let address = "ws://new.example.test:8765/tabletop"
        try await transport.append(sessionWelcome(paired: false))
        let session = WorldSession(scene: BatchScene(), tokenStorage: tokens, linkConfiguration: sessionConfig(), transportFactory: { transport })
        await session.connect(address)
        try await sessionEventually { await transport.messages().contains { $0.s("type") == "pair_request" } }
        #expect(tokens.find(address, "test-server")?.token == "saved-test-token")
        await session.disconnect()
    }

    @Test func persistenceFailureStillRequestsPairing() async throws {
        let transport = SessionTransport()
        try await transport.append(sessionWelcome(paired: false))
        let session = WorldSession(scene: BatchScene(), tokenStorage: UnavailableTokens(), linkConfiguration: sessionConfig(), transportFactory: { transport })
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { await transport.messages().contains { $0.s("type") == "pair_request" } }
        #expect(await session.latest().lastError.contains("storage unavailable"))
        #expect(await session.latest().tokenSaved == false)
        await session.disconnect()
    }

    @Test func snapshotsSpecialsAndLiveUpdatesReachRetainedBatches() async throws {
        let scene = BatchScene(), transport = SessionTransport()
        try await transport.append(sessionWelcome(paired: true))
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0], "dims": [1,1,1],
                                    "order": "yzx", "encoding": "rle_palette_v1", "palette": ["minecraft:torch", "minecraft:gold_block"], "data": [0,1]])
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), linkConfiguration: sessionConfig(), transportFactory: { transport })
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { scene.snapshot().batches.values.contains { !$0.data.verts.isEmpty } }
        let before = try #require(scene.snapshot().batches.values.first)
        #expect(before.blockSize == 0.1) // Clamped for this tiny region.
        #expect(before.center == [0.5, 0, 0.5])
        try await transport.append(["type": "block_update", "snapshot_id": 1, "changes": [[0,0,0,1]]])
        let gold = BlockRules.flatColor("minecraft:gold_block")
        try await sessionEventually { scene.snapshot().batches.values.contains { $0.data.verts.allSatisfy { $0.color == gold } && !$0.data.verts.isEmpty } }
        #expect(await session.latest().percent == 100)
        await session.disconnect()
    }

    @Test func paletteGrowthKeepsGenerationAndOnlyUpdatesDirtyBatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scene = BatchScene(), transport = SessionTransport()
        try await transport.append(sessionWelcome(paired: true))
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0], "dims": [64,16,16],
                                    "order": "yzx", "encoding": "rle_palette_v1", "palette": ["minecraft:stone"], "data": [0,16384]])
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), assetDirectory: directory,
                                   linkConfiguration: sessionConfig(), transportFactory: { transport })
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { await session.latest().percent == 100 && scene.snapshot().batches.count == 2 }
        let initial = scene.snapshot(), epoch = initial.generation
        let untouched = try #require(initial.batches[[1,0,0]])
        for (offset, state) in ["minecraft:copper_block", "minecraft:oxidized_copper", "minecraft:gold_block"].enumerated() {
            let paletteID = offset + 1
            try await transport.append(["type": "block_update", "snapshot_id": 1,
                                        "palette_add": [.string(state)], "changes": [[1,15,1,.number(Double(paletteID))]]])
            let color = BlockRules.flatColor(state)
            try await sessionEventually { scene.snapshot().batches[[0,0,0]]?.data.verts.contains { $0.color == color } == true }
            #expect(scene.snapshot().generation == epoch)
            #expect(scene.snapshot().batches[[1,0,0]]?.data.indices == untouched.data.indices)
            #expect(scene.snapshot().batches[[1,0,0]]?.data.verts.count == untouched.data.verts.count)
        }
        await session.disconnect()
    }

    @Test func assetStatusWaitsForWelcomeAndOfferGrace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = SessionTransport()
        let session = WorldSession(scene: BatchScene(), tokenStorage: SessionTokens(), assetDirectory: directory,
                                   linkConfiguration: sessionConfig(), transportFactory: { transport })
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { await session.latest().assets == "Waiting for asset offer" }
        var welcome = sessionWelcome(paired: true); welcome["caps"] = ["pair_v1", "assets_v1"]
        try await transport.append(welcome)
        try await sessionEventually { await session.latest().connected }
        #expect(await session.latest().assets != "not offered by this server")
        try await transport.append(["type": "assets", "state": "ready", "files": []])
        try await sessionEventually { await session.latest().assets == "the server offers nothing" }
        await session.disconnect()
    }

    @Test func failedAndInterruptedCachedPackStaysQuarantinedUntilImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appendingPathComponent("pack.zip")
        try Data("invalid zip".utf8).write(to: installed)
        let firstTransport = SessionTransport()
        let first = WorldSession(scene: BatchScene(), tokenStorage: SessionTokens(), assetDirectory: directory,
                                 linkConfiguration: sessionConfig(), transportFactory: { firstTransport })
        await first.connect("ws://example.test:8765/tabletop")
        #expect(await first.latest().pack.contains("Pack disabled"))
        let marker = directory.appendingPathComponent("pack-load-failure.txt")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        await first.disconnect()
        // Even a now-valid file is not silently retried after an interrupted load.
        let source = try atlasZip(atlasFluidEntries())
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(contentsOf: source).write(to: installed)
        try "previous pack load did not finish".write(to: marker, atomically: true, encoding: .utf8)
        let transport = SessionTransport()
        let second = WorldSession(scene: BatchScene(), tokenStorage: SessionTokens(), assetDirectory: directory,
                                  linkConfiguration: sessionConfig(), transportFactory: { transport })
        await second.connect("ws://example.test:8765/tabletop")
        #expect(await second.latest().pack.contains("previous pack load did not finish"))
        #expect(await second.importPack(source))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await second.latest().pack.contains("pack.zip"))
        await second.disconnect()
    }


    @Test func movingPistonHeadIsPrewarmedWithoutPaletteGrowth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var entries = try atlasFluidEntries()
        // Vanilla's moving placeholder has an empty model. Without this fixture
        // override, the asset-free classifier uses a cube and bypasses movingShown.
        entries.append(("assets/minecraft/blockstates/moving_piston.json", Array(#"{"variants":{"":{"model":"test:empty"}}}"#.utf8), false))
        entries.append(("assets/test/models/empty.json", Array(#"{"elements":[]}"#.utf8), false))
        entries.append(("assets/minecraft/blockstates/piston_head.json", Array(#"{"variants":{"":{"model":"test:head"}}}"#.utf8), false))
        entries.append(("assets/test/models/head.json", Array(##"{"textures":{"all":"test:water_still"},"elements":[{"from":[0,0,0],"to":[16,16,16],"faces":{"west":{"texture":"#all"},"east":{"texture":"#all"},"up":{"texture":"#all"}}}]}"##.utf8), false))
        let source = try atlasZip(entries)
        defer { try? FileManager.default.removeItem(at: source) }
        let scene = BatchScene(), transport = SessionTransport()
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), assetDirectory: directory,
                                   linkConfiguration: sessionConfig(), transportFactory: { transport })
        #expect(await session.importPack(source))
        try await transport.append(sessionWelcome(paired: true))
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0], "dims": [4,1,1],
                                    "order": "yzx", "encoding": "rle_palette_v1",
                                    "palette": ["minecraft:air", "minecraft:piston[extended=false,facing=east]", "minecraft:stone",
                                                "minecraft:piston[extended=true,facing=east]", "minecraft:moving_piston[facing=east,type=normal]"],
                                    "data": [1,1,2,1,0,2]])
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { await session.latest().percent == 100 && !scene.snapshot().batches.isEmpty }
        let epoch = scene.snapshot().generation
        #expect(scene.snapshot().batches.values.allSatisfy { $0.data.verts.allSatisfy { $0.uv.z < 0 } })
        try await transport.append(["type": "block_update", "snapshot_id": 1, "changes": [[0,0,0,3],[1,0,0,4]]])
        try await sessionEventually { scene.snapshot().batches.values.contains { $0.data.verts.contains { $0.uv.z >= 0 } } }
        #expect(scene.snapshot().generation == epoch)
        await session.disconnect()
    }


    @Test func gpuPackFailureSurfacesStatusAndRemeshesTrueFlatColours() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var entries = try atlasFluidEntries()
        entries.append(("assets/minecraft/blockstates/stone.json", Array(#"{"variants":{"":{"model":"test:stone"}}}"#.utf8), false))
        entries.append(("assets/test/models/stone.json", Array(##"{"textures":{"all":"test:water_still"},"elements":[{"from":[0,0,0],"to":[16,16,16],"faces":{"up":{"texture":"#all"}}}]}"##.utf8), false))
        let source = try atlasZip(entries)
        defer { try? FileManager.default.removeItem(at: source) }
        let atlas = try ResourcePackAtlas(path: source.path)
        atlas.prewarm(["minecraft:stone"])
        let valid = try atlas.checkedBaked()
        let invalid = BakedResourcePack(faces: valid.faces, models: valid.models, shapeOverrides: valid.shapeOverrides,
                                       tileSize: 257, layerNames: valid.layerNames, layers: valid.layers, mips: valid.mips,
                                       animations: valid.animations, solidLayers: valid.solidLayers, randomUv: valid.randomUv,
                                       randomTables: valid.randomTables, colormaps: valid.colormaps)
        let scene = BatchScene(), transport = SessionTransport()
        let mailbox = try scene.attach(device: #require(MTLCreateSystemDefaultDevice()))
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), assetDirectory: directory,
                                   linkConfiguration: sessionConfig(), transportFactory: { transport })
        #expect(await session.importPack(source))
        try await transport.append(sessionWelcome(paired: true))
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0], "dims": [1,1,1],
                                    "order": "yzx", "encoding": "rle_palette_v1", "palette": ["minecraft:stone"], "data": [0,1]])
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { await session.latest().percent == 100 && !scene.packPreparationPending }
        let epoch = scene.snapshot().generation
        scene.updatePack(invalid, generation: epoch)
        let flat = BlockRules.flatColor("minecraft:stone")
        try await sessionEventually {
            let current = scene.snapshot()
            return current.generation > epoch && !current.batches.isEmpty &&
                current.batches.values.allSatisfy { !$0.data.verts.isEmpty && $0.data.verts.allSatisfy { $0.color == flat && $0.uv.z < 0 } }
        }
        #expect(await session.latest().pack.contains("Render error"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pack-load-failure.txt").path))
        withExtendedLifetime(mailbox) {}
        await session.disconnect()
    }


    @Test(arguments: [false, true])
    func snapshotPrewarmGatesOldMeshCompletionAndSurvivesSettingsChange(changeSettings: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var entries = try atlasFluidEntries()
        // A synthetic model keeps background preparation in flight long enough
        // for the old mesh round (or a settings generation) to finish first.
        let element = ##"{"from":[0,0,0],"to":[16,16,16],"faces":{"west":{"texture":"#all"},"east":{"texture":"#all"},"up":{"texture":"#all"}}}"##
        let model = "{\"textures\":{\"all\":\"test:water_still\"},\"elements\":[" + Array(repeating: element, count: 10_000).joined(separator: ",") + "]}"
        entries.append(("assets/test/blockstates/slow.json", Array(#"{"variants":{"":{"model":"test:slow"}}}"#.utf8), false))
        entries.append(("assets/test/models/slow.json", Array(model.utf8), true))
        let source = try atlasZip(entries)
        defer { try? FileManager.default.removeItem(at: source) }
        let scene = BatchScene(), transport = SessionTransport()
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), assetDirectory: directory,
                                   linkConfiguration: sessionConfig(), transportFactory: { transport })
        #expect(await session.importPack(source))
        try await transport.append(sessionWelcome(paired: true))
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0],
                                    "dims": changeSettings ? [1,1,1] : [64,16,64], "order": "yzx", "encoding": "rle_palette_v1",
                                    "palette": ["test:plain"], "data": changeSettings ? [0,1] : [0,65536]])
        await session.connect("ws://example.test:8765/tabletop", meshWorkers: 1)
        try await sessionEventually("race: initial mesh") { !scene.snapshot().batches.isEmpty }
        if changeSettings { try await sessionEventually("race: initial completion") { await session.latest().percent == 100 } }
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 2, "world": "world", "origin": [0,0,0], "dims": [1,1,1],
                                    "order": "yzx", "encoding": "rle_palette_v1", "palette": ["test:slow"], "data": [0,1]])
        try await sessionEventually("race: preparation started") { await session.latest().packLoading }
        if changeSettings { var prefs = AppPrefs(); prefs.brightness = 0.7; await session.configure(prefs) }
        try await sessionEventually("race: preparation finished") { await !session.latest().packLoading }
        try await sessionEventually("race: remesh completed") { await session.latest().percent == 100 }
        #expect(scene.snapshot().batches.values.reduce(0) { $0 + $1.data.verts.filter { $0.uv.z >= 0 }.count } == 120_000)
        let epoch = scene.snapshot().generation
        try await transport.append(["type": "block_update", "snapshot_id": 2, "changes": [[0,0,0,0]]])
        try await sessionEventually { let status = await session.latest(); return status.percent == 100 && !status.packLoading }
        #expect(scene.snapshot().generation == epoch)
        #expect(scene.snapshot().batches.values.reduce(0) { $0 + $1.data.verts.filter { $0.uv.z >= 0 }.count } == 120_000)
        await session.disconnect()
    }


    @Test func olderGPUUploadCannotClearNewerCPUPackFailureQuarantine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var entries = try atlasFluidEntries()
        // Only the header is needed: frame limits must reject before PNG decoding.
        var header = try #require(entries.first { $0.0.hasSuffix("water_flow.png") }).1
        header.replaceSubrange(16..<24, with: [0,0,0,128,0,0,0,128])
        entries.append(("assets/test/textures/bomb.png", header, false))
        entries.append(("assets/test/textures/bomb.png.mcmeta", Array(#"{"animation":{"width":1,"height":1}}"#.utf8), false))
        entries.append(("assets/test/blockstates/bomb.json", Array(#"{"variants":{"":{"model":"test:bomb"}}}"#.utf8), false))
        entries.append(("assets/test/models/bomb.json", Array(##"{"textures":{"all":"test:bomb"},"elements":[{"from":[0,0,0],"to":[16,16,16],"faces":{"up":{"texture":"#all"}}}]}"##.utf8), false))
        let source = try atlasZip(entries)
        defer { try? FileManager.default.removeItem(at: source) }
        let scene = BatchScene(), transport = SessionTransport()
        let session = WorldSession(scene: scene, tokenStorage: SessionTokens(), assetDirectory: directory,
                                   linkConfiguration: sessionConfig(), transportFactory: { transport })
        #expect(await session.importPack(source))
        try await transport.append(sessionWelcome(paired: true))
        try await transport.append(["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0], "dims": [1,1,1],
                                    "order": "yzx", "encoding": "rle_palette_v1", "palette": ["test:plain"], "data": [0,1]])
        await session.connect("ws://example.test:8765/tabletop")
        try await sessionEventually { await session.latest().percent == 100 }
        #expect(scene.packPreparationPending) // No renderer has attached yet.
        try await transport.append(["type": "block_update", "snapshot_id": 1, "palette_add": ["test:bomb"], "changes": [[0,0,0,1]]])
        try await sessionEventually { await session.latest().pack.contains("disabled") }
        let marker = directory.appendingPathComponent("pack-load-failure.txt")
        let failure = try String(contentsOf: marker, encoding: .utf8)
        #expect(failure.contains("16384"))
        let mailbox = try scene.attach(device: #require(MTLCreateSystemDefaultDevice()))
        try await sessionEventually { !scene.packPreparationPending }
        // Give the pump time to observe the older successful GPU preparation.
        try await Task.sleep(for: .milliseconds(80))
        #expect(try String(contentsOf: marker, encoding: .utf8) == failure)
        #expect(await session.latest().pack.contains("disabled"))
        withExtendedLifetime(mailbox) {}
        await session.disconnect()
    }

}
