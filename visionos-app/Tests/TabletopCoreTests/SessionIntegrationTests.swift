import Foundation
import Metal
import Synchronization
import Testing
import TabletopCore
@testable import TabletopRender
import TabletopSpatial

private func sessionEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw JsonError("session timed out") }
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
}
