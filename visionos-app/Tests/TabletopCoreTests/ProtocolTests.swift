// Parity tests for quest-app/Assets/Scripts/Net/Protocol.cs at 9ce237e and Net/Json.cs at 37baed1.
import Foundation
import Testing
@testable import TabletopCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tools/fixtures")

func protocolFixture(_ name: String) throws -> JSONObject {
    try #require(Json.parse(String(contentsOf: fixtures.appendingPathComponent(name + ".json"), encoding: .utf8)).objectValue)
}

struct ProtocolTests {
    @Test func all57M1FixtureVariantsRoundTripAndDecode() throws {
        let types: Set<String> = ["hello", "welcome", "subscribe", "chunk_snapshot", "block_update", "player_positions",
            "pose", "avatar_config", "avatar_state", "ping", "pong", "error", "bye", "region_request", "region_query",
            "region_info", "region_changed", "pair_request", "pair_code", "paired"]
        var count = 0
        for url in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where url.pathExtension == "json" {
            let m = try #require(Json.parse(String(contentsOf: url, encoding: .utf8)).objectValue)
            guard let type = m.s("type"), types.contains(type) else { continue }
            count += 1
            #expect(try Json.parse(Json.stringify(m)) == .object(m), Comment(rawValue: url.lastPathComponent))
            #expect(m.i("v") == 1)
            switch type {
            case "welcome": #expect(try Welcome.from(m).protocol == 1)
            case "chunk_snapshot":
                if m.s("encoding") == "rle_palette_v1" { #expect(try ChunkSnapshot.from(m).grid.count > 0) }
            case "block_update": #expect(try BlockUpdate.from(m).snapshotId == m.i("snapshot_id"))
            case "player_positions":
                for p in m.a("players") ?? [] { _ = try PlayerInfo.from(#require(p.objectValue)) }
            case "pose":
                let head = try TabletopPose.from(#require(m.o("head")))
                #expect(head.p.z > 0) // already tabletop coordinates; no Z reflection
                for hand in ["left", "right"] { if let o = m.o(hand) { _ = try TabletopPose.from(o) } }
            case "region_info": #expect(try RegionInfo.from(m).refSeq != nil)
            case "region_changed": #expect(try RegionChanged.from(m).world == m.s("world"))
            case "avatar_state": #expect(AvatarState.from(m).scale == m.d("scale"))
            case "error": #expect(try ProtocolError.from(m).code == m.s("code"))
            case "pair_code": #expect(PairCode.from(m, 0)?.code == m.s("code"))
            default: break
            }
        }
        #expect(count == 57)
    }

    @Test func buildersEqualParsedGoldenFixtures() throws {
        func compare(_ name: String, _ body: JSONObject) throws {
            let fixture = try protocolFixture(name)
            var built = body
            for key in ["v", "seq", "t"] { built[key] = fixture[key] }
            #expect(try Json.parse(Json.stringify(built)) == .object(fixture), Comment(rawValue: name))
        }
        try compare("subscribe", Protocol.subscribe("world", origin: [100, 60, -40], dims: [32, 64, 32]))
        try compare("region_request", Protocol.regionRequest("world", center: [12.5, 70, -40.5], size: [64, 96, 64], yOrigin: 32))
        for name in ["region_request_jump", "region_request_resize", "region_request_nav"] {
            let f = try protocolFixture(name)
            let origin = try Json.ints(f.a("origin")), dims = try Json.ints(f.a("dims"))
            let margin = try Json.ints(f.a("view_margin"))
            try compare(name, Protocol.regionRequest(f.s("world") ?? "", origin: Int3(origin[0], origin[1], origin[2]),
                dims: Int3(dims[0], dims[1], dims[2]), viewMargin: Int3(margin[0], margin[1], margin[2])))
        }
        try compare("region_query", Protocol.regionQuery())
        let ping = try protocolFixture("ping")
        try compare("ping", Protocol.ping(ping.i("id")))
        let pong = try protocolFixture("pong")
        try compare("pong", Protocol.pong(["id": pong["id"] ?? .null, "t": pong["echo_t"] ?? .null]))
        let bye = try protocolFixture("bye")
        try compare("bye", Protocol.bye(bye.s("reason") ?? ""))
        var avatar = Protocol.avatarConfig(true, blockSizeM: 0.01, skinPlayer: "PlayerName", showHands: true, nameTag: "Tabletop Giant")
        // These optional fields are not set by the C# builder, but callers may supply them.
        avatar["skin_url"] = .null; avatar["model"] = "wide"
        try compare("avatar_config", avatar)
        #expect(avatar.d("block_size_m") == 0.01)
        let pose = try protocolFixture("pose")
        let head = try TabletopPose.from(#require(pose.o("head")))
        let left = try TabletopPose.from(#require(pose.o("left")))
        let right = try TabletopPose.from(#require(pose.o("right")))
        try compare("pose", Protocol.pose(123456789, head: head, left: left, right: right))
        #expect(head.tracked && head.toJson()["tracked"] == nil)
        #expect(TabletopPose().toJson()["tracked"] == true)
        let pair = try protocolFixture("pair_request")
        try compare("pair_request", PairingProtocol.request(pair.s("device_name")))
        // Exact M1 hello differs intentionally in identity and capabilities from the older Quest fixture.
        var hello = try protocolFixture("hello_pair")
        let built = Protocol.hello(hello.s("token"), deviceToken: hello.s("device_token"), deviceName: "Apple Vision Pro", clientVersion: hello.s("client_version") ?? "")
        hello["client"] = "visionos-app"; hello["device_name"] = "Apple Vision Pro"
        hello["caps"] = .array(Protocol.capabilities.map(JSONValue.string))
        var wrapped = built
        for k in ["v", "seq", "t"] { wrapped[k] = hello[k] }
        #expect(try Json.parse(Json.stringify(wrapped)) == .object(hello))
        #expect(Protocol.capabilities == ["rle_palette_v1", "avatar", "light_v1", "biomes_v1", "sections_v1", "pair_v1", "assets_v1"])
        let error = try protocolFixture("error")
        try compare("error", Protocol.error(error.s("code") ?? "", message: error.s("message") ?? "", refSeq: UInt32(error.i("ref_seq")), fatal: error.b("fatal")))
    }

    @Test func envelopeStartsAtZeroReservesTrackedAndWrapsUInt32() {
        var e = Envelope()
        #expect(e.wrap(["type": "hello"], t: 1234).i("seq") == 0)
        let tracked = e.reserve()
        #expect(tracked == 1)
        #expect(e.wrap(["type": "ping"], t: 1234).i("seq") == 2)
        let m = e.wrap(["type": "region_query"], seq: tracked, t: 5678)
        #expect(m.i("seq") == 1 && m.i("v") == 1 && m.d("t") == 5678)
        e = Envelope(nextSeq: .max)
        #expect(e.wrap([:], t: 0).d("seq") == Double(UInt32.max))
        #expect(e.wrap([:], t: 0).i("seq") == 0)
    }

    @Test func snapshotYzxAndOptionalExtras() throws {
        let s = try ChunkSnapshot.from(protocolFixture("chunk_snapshot"))
        #expect(s.snapshotId == 7 && s.world == "world" && s.origin == [100, 60, -40] && s.dims == [32, 64, 32])
        #expect(s.grid.count == 65536 && s.grid[40959] == 0 && s.grid[40960] == 1 && s.grid[61440] == 2)
        #expect(s.light == nil && s.biomes == nil)
        let extras = try ChunkSnapshot.from(protocolFixture("chunk_snapshot_extras"))
        #expect(extras.grid.count == 32 && extras.grid[31] == 2)
        #expect(extras.light?[30] == 254 && extras.biomes != nil)
    }

    @Test func malformedRleAndSnapshotFieldsThrow() throws {
        let invalidRuns: [[JSONValue]] = [[0], [0, 0], [0, -1], [-1, 1], [2, 1], [0, 2], [0.5, 1], [0, 1.5], [0, 1e100], []]
        for data in invalidRuns {
            #expect(throws: (any Error).self) { try ChunkSnapshot.decodeRle(data, 1, 2) }
        }
        let invalidFields: [(String, JSONValue)] = [("dims", [1, 2]), ("dims", [0, 1, 1]), ("dims", [1e100, 1, 1]),
            ("order", "xyz"), ("encoding", "unknown"), ("light", false), ("biomes", 1), ("palette", [1]), ("data", nil)]
        for (key, value) in invalidFields {
            var s = try protocolFixture("chunk_snapshot"); s[key] = value
            #expect(throws: (any Error).self) { try ChunkSnapshot.from(s) }
        }
        #expect(throws: (any Error).self) { try ChunkSnapshot.decodeLight(["encoding": "rle_v1", "data": [256, 1]], 1) }
    }

    @Test func jsonGrammarUnicodeNumbersAndAccessors() throws {
        let value: JSONValue = ["unicode": "🧱 café", "quote": "\"\\\n\u{0001}", "array": [nil, true, -10, 1.25e4], "object": [:]]
        #expect(try Json.parse(Json.stringify(value)) == value)
        #expect(try Json.parse(#""\uD83E\uDDF1""#) == "🧱")
        #expect(try Json.parse("-123456789012345") == .number(-123456789012345))
        #expect(try Json.parse("1760370003000") == .number(1760370003000))
        #expect(try Json.parse("123456789012345678") == .number(123456789012345678))
        #expect(try Json.parse("-0.01e+2") == -1)
        for text in ["", "[", "{", "[1,]", "{\"x\":}", "{\"a\" 1}", "true false", "01", "1.", "1e", "--1", "NaN", "1e999", #""\x""#, #""\uD800""#, #""\uDC00""#] {
            #expect(throws: (any Error).self) { try Json.parse(text) }
        }
        #expect(throws: (any Error).self) { try Json.stringify(.number(.nan)) }
        #expect(throws: (any Error).self) { try Json.parse(String(repeating: "[", count: 300)) }
        let d: JSONObject = ["s": "x", "i": 2.9, "b": true, "a": [], "o": [:], "bad": 1e100]
        #expect(d.s("s") == "x" && d.i("i") == 2 && d.d("missing", 3) == 3 && d.b("b"))
        #expect(d.a("a") == [] && d.o("o") == [:] && d.i("bad", -1) == -1 && d.s("i") == nil)
    }
}
