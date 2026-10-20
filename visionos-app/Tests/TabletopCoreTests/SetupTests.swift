// Ported from quest-app/Tests~/SetupTests.cs @ 6017fc2.
// Also covers owned helpers from ComfortTests.cs and AreaTests.cs / Program.cs.
import Foundation
import Darwin
import Testing
@testable import TabletopCore

private func setupFixture(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("tools/fixtures/\(name).json"), encoding: .utf8)
}
private func setupObject(_ json: String) throws -> JSONObject {
    try #require(Json.parse(json).objectValue)
}

struct SetupTests {
    @Test func areaFitAndBudgets() {
        #expect(abs(AreaMath.fitBlockSize(1.2, 0.8, 64, 64, 1) - 0.0125) < 1e-6)
        #expect(abs(AreaMath.fitBlockSize(1.2, 0.8, 128, 32, 1) - 1.2 / 128) < 1e-6)
        #expect(AreaMath.fitBlockSize(0.5, 0.5, 100000, 100000) == AreaMath.minBlockM)
        #expect(AreaMath.fitBlockSize(10, 10, 1, 1) == AreaMath.maxBlockM)
        #expect(AreaMath.fitBlockSize(0, 1, 16, 16) == 0.01)
        #expect(AreaMath.fitBlockSize(1, 1, 0, 16) == 0.01)
        let e32 = AreaMath.estimate(32, 96, 32)
        #expect(e32.quads == 5632 && e32.vertices == 22528 && e32.triangles == 11264)
        #expect(e32.description == "~5k faces / ~22k verts")
        #expect(AreaMath.estimate(64, 96, 64).quads == e32.quads * 4)
        #expect(AreaMath.estimate(32, 384, 32).quads > e32.quads * 3)
        #expect(!AreaMath.overBudget(AreaMath.estimate(128, 128, 128), AreaMath.defaultQuadBudget, false))
        #expect(AreaMath.overBudget(AreaMath.estimate(128, 384, 128), AreaMath.defaultQuadBudget, false))
        #expect(!AreaMath.overBudget(AreaMath.estimate(512, 384, 512), AreaMath.defaultQuadBudget, true))
        let (x, y, z) = AreaMath.clampToCaps(300, 384, 300, 128, 384, 128, 2097152)
        #expect(x == 128 && y == 128 && z == 128)
        #expect(AreaMath.sections(17, 32, 33) == 12)
        #expect(AreaMath.estimateSections(17, 32, 33) == 6)
        #expect(AreaMath.estimateMeshes(64, 96, 64) == 9)
        #expect(AreaMath.estimateMeshes(64, 0, 64) == 0)
        #expect(AreaMath.estimateMeshes(64, 96, 64, columns: 1) == 25)
        let base = AreaMath.estimate(128, 96, 128)
        var lit = AreaMath(); lit.lightFactor = AreaMath.lightFactorFor(true, true)
        #expect(lit.estimate(128, 96, 128).quads == Int64(ceil(Double(base.quads) * 1.35)))
        #expect(AreaMath.lightFactorFor(true, false) == 1.15)
        #expect(AreaMath.lightFactorFor(false, true) == 1)
    }

    @Test func sessionHealthTransitions() {
        var h = LinkHealth(); h.newServer(0); h.update(false, 1)
        #expect(!h.showCard(false, 4.9) && h.showCard(false, 5) && !h.offline)
        #expect(h.showCard(true, 0.1))
        h.update(true, 6)
        #expect(h.everConnected && !h.showCard(false, 7) && !h.offline && !h.hideFigures(7))
        h.update(false, 10); h.update(false, 11)
        #expect(h.offline && !h.showCard(false, 30) && !h.hideFigures(11) && h.hideFigures(11.5))
        h.update(true, 12)
        #expect(!h.offline && !h.hideFigures(13))
        h.newServer(20)
        #expect(!h.everConnected && !h.offline && h.showCard(false, 25))
    }

    @Test func loadingAndHold() {
        var load = LoadProgress(); load.begin(10)
        #expect(!load.active && load.text(5) == nil)
        load.begin(200)
        #expect(load.text(200) == "Loading area 0 %")
        #expect(load.text(120) == "Loading area 40 %")
        #expect(load.text(250) == "Loading area 0 %")
        #expect(load.text(0) == "Area loaded" && !load.active && load.text(0) == nil)
        load.begin(100); load.cancel(); #expect(!load.active)
        var a = HoldButton()
        #expect(a.update(true, 0, false) == .pressed)
        #expect(a.update(true, 0.3, false) == .none)
        #expect(a.progress(0.25) == 0.5)
        #expect(a.update(true, 0.5, false) == .fired)
        #expect(a.update(true, 0.9, false) == .none)
        #expect(a.update(false, 1, false) == .released)
        #expect(a.update(true, 2, false) == .pressed)
        #expect(a.update(false, 2.2, false) == .released)
        a.update(true, 3, false)
        #expect(a.update(true, 3.2, true) == .none)
        #expect(a.update(true, 3.8, false) == .none && a.progress(3.8) == 0)
        #expect(a.update(false, 4, false) == .none)
        #expect(a.update(true, 5, true) == .none)
        #expect(a.update(true, 6, false) == .none)
        a.update(false, 7, false)
        #expect(a.update(true, 8, false) == .pressed)
    }

    @Test func firstRunAndCards() throws {
        var run = FirstRun(); run.active = true
        #expect(run.shouldSearch(0, false) && !run.shouldSearch(0, true))
        #expect(SetupCard.firstRunText(run).contains("Looking for your Minecraft server"))
        var port = FoundServer(); port.portOnly = true; port.url = "ws://10.0.0.9:8765/tabletop"
        #expect(run.searched([port], 1) == nil && run.candidates == 0)
        #expect(!run.shouldSearch(8.9, false) && run.shouldSearch(9, false))
        #expect(SetupCard.firstRunText(run).contains("No server found"))
        var real = FoundServer(); real.url = "ws://10.0.0.5:8765/tabletop"
        #expect(run.searched([port, real], 10) == real.url && run.candidates == 1)
        #expect(run.searched([real, real], 20) == nil && run.candidates == 2)
        #expect(SetupCard.firstRunText(run).contains("Found 2 servers"))
        run.done(); #expect(!run.shouldSearch(100, false) && run.searched([real], 100) == nil)
        #expect(SetupCard.firstRunText(run).contains(SetupCard.disclaimer))
        let card = SetupCard.text(real.url, "Connection refused", 0, "", "/tmp/tabletop.json")
        #expect(card.hasPrefix(SetupCard.title) && card.contains(real.url) && card.contains("Retrying..."))
        #expect(SetupCard.text(real.url, "", 4003, "wrong token", "").contains("Not retrying"))
        #expect(SetupCard.text(real.url, "", 4001, "", "").hasPrefix("App and server don't match"))
        let code = try #require(PairCode.from(setupObject(setupFixture("pair_code")), 0))
        let pair = SetupCard.pairText(code, 61, "10.0.0.5")
        #expect(pair.contains("482 913") && pair.contains("3:59") && pair.contains("tabletop pair 482913"))
    }

    @Test func prefsRoundTripAndCallerDirectory() throws {
        var p = AppPrefs()
        p.server = "ws://example.test:8765/tabletop"
        p.meshWorkers = 5
        p.blockSizeM = 0.0042; p.areaWidth = 192; p.showHud = true; p.menuTab = "natural"
        p.hotbar = ["minecraft:stone", "minecraft:oak_stairs", nil, nil, nil, nil, nil, nil, nil]
        p.hotbarSelected = 1; p.selected = "minecraft:oak_stairs"; p.volume = 0.42; p.sound = false
        p.tableAnchor = "test-anchor"; p.table = TablePose(x: 0.1, y: 0.02, z: -0.05, yaw: 30)
        p.chatSafety = ["server": .object(["muted": .array([.string("test-player")])])]
        p.seeConfig(["block_size_m": .number(0.01), "show_hud": .bool(false), "server": .string("ignored")])
        let json = try p.toJson(), back = try AppPrefs.parse(json)
        #expect(back.server == p.server)
        #expect(back.meshWorkers == 5)
        #expect(try AppPrefs.parse("{\"mesh_workers\":999}").meshWorkers == 8)
        #expect(try AppPrefs.parse("{\"mesh_workers\":0}").meshWorkers == 1)
        #expect(back.blockSizeM == p.blockSizeM && back.areaWidth == 192 && back.showHud == true)
        #expect(back.hotbar == p.hotbar && back.hotbarSelected == 1 && back.selected == p.selected)
        #expect(back.volume == 0.42 && back.sound == false && back.table == p.table)
        #expect(back.chatSafety == p.chatSafety && back.seen == p.seen && back.seen["server"] == nil)
        #expect(json.contains("\n  \"block_size_m\": "))
        #expect(try json == back.toJson())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tabletop-prefs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try AppPrefs.load(from: dir).blockSizeM == nil)
        try p.save(to: dir)
        #expect(try AppPrefs.load(from: dir).toJson() == json)
        #expect(try AppPrefs.parse("").table == nil)
        #expect(throws: (any Error).self) { try AppPrefs.parse("[1]") }
        #expect(throws: (any Error).self) { try AppPrefs.parse("{broken") }
        p.volume = .nan
        #expect(throws: (any Error).self) { try p.toJson() }
    }

    @Test func prefsParsingAndPrecedence() throws {
        let p = try AppPrefs.parse("""
        {"block_size_m":-1,"area_width":-4,"volume":3,"sound":true,"show_hud":"bad",
        "hotbar":["a",null,3,"d","e","f","g","h","i","j"],"table":{"anchor":"","pos":[1,2,3]},
        "tabletop_json":{"volume":0.5,"sound":false,"show_hud":"bad","server":"bad"}}
        """)
        #expect(p.blockSizeM == nil && p.areaWidth == 0 && p.volume == 1 && p.showHud == nil)
        #expect(p.hotbar?.count == 9 && p.hotbar?[2] == nil && p.table == nil)
        #expect(p.seen.count == 2)
        #expect(AppPrefs.pick(.number(0.01), .number(0.004), nil) == .number(0.01))
        #expect(AppPrefs.pick(.number(0.01), .number(0.004), .number(0.01)) == .number(0.004))
        #expect(AppPrefs.pick(.number(0.02), .number(0.004), .number(0.01)) == .number(0.02))
        #expect(AppPrefs.pick(nil, .number(0.004), .number(0.01)) == .number(0.004))
        #expect(AppPrefs.pick(nil, nil, nil) == nil)
        #expect(AppPrefs.pick(.null, .number(0.004), .null) == .number(0.004))
        #expect(AppPrefs.pick(.bool(true), .bool(false), .bool(true)) == .bool(false))
    }

    @Test func poseAndDebounce() throws {
        let ref = Float3(1.2, 0.74, -0.4), anchor = Float3(1.35, 0.76, -0.6)
        let rel = TablePose.relative(ref, 40, anchor, 100)
        let (back, yaw) = rel.compose(ref, 40)
        #expect(abs(back.x - anchor.x) < 1e-4 && abs(back.y - anchor.y) < 1e-4 && abs(back.z - anchor.z) < 1e-4)
        #expect(abs(yaw - 100) < 1e-3)
        let r90 = TablePose.rotY(Float3(0, 0, 1), 90)
        #expect(abs(r90.x - 1) < 1e-5 && abs(r90.z) < 1e-5)
        #expect(TablePose.wrap(370) == 10 && TablePose.wrap(-190) == 170 && TablePose.wrap(-180) == 180)
        let unchanged = TablePose.relative(.zero, 0, Float3(1, 2, 3), 0)
        #expect(unchanged.z == 3) // No Unity Z mirror.
        var saver = PrefsSaver(); saver.saved("A")
        #expect(saver.offer("A", 0) == nil)
        #expect(saver.offer("B", 1) == nil && saver.offer("B", 2) == nil && saver.offer("B", 2.6) == "B")
        saver.saved("B"); #expect(saver.offer("B", 3) == nil)
        for i in 0..<9 { #expect(saver.offer("Z\(i)", Double(10 + i)) == nil) }
        #expect(saver.offer("Z9", 20.1) == "Z9")
        #expect(saver.flush("B2") == "B2" && saver.flush(nil) == nil)
        let cfg = try ConfigFile.withServer("{\"server\":\"old\",\"token\":\"t\",\"block_size_m\":0.01}", "ws://new:8765/tabletop")
        let c = try setupObject(cfg)
        #expect(c.s("server") == "ws://new:8765/tabletop" && c.s("token") == "t" && c.d("block_size_m") == 0.01)
        #expect(try setupObject(ConfigFile.withServer(nil, "ws://a:1/x")).s("server") == "ws://a:1/x")
        #expect(throws: (any Error).self) { try ConfigFile.withServer("[1]", "x") }
    }

    @Test func tokenStore() throws {
        var s = MemoryTokenStorage()
        s.save("idA", "ws://10.0.0.5:8765/tabletop", "tokA", "a1", "Apple Vision Pro", 1)
        s.save("idB", "ws://10.0.0.9:8765/tabletop", "tokB", "b1", "Apple Vision Pro", 2)
        #expect(s.tokenFor("ws://10.0.0.5:8765/tabletop", nil) == "tokA")
        #expect(s.tokenFor("ws://elsewhere/t", "idA") == "tokA")
        #expect(s.seen("ws://10.0.0.6:8765/tabletop", "idA") == true)
        #expect(s.seen("ws://10.0.0.6:8765/tabletop", "idA") == false)
        s.save("idA", "ws://10.0.0.6:8765/tabletop", "tokC", "c1", "Apple Vision Pro", 3)
        #expect(s.entries.count == 2 && s.tokenFor(nil, "idA") == "tokC")
        var back = try PairingStore.parse(s.toJson())
        #expect(back.entries == s.entries)
        #expect(back.forget("ws://10.0.0.9:8765/tabletop", nil) == true)
        #expect(back.forget("missing", "missing") == false)
        #expect(back.tokenFor(nil, "idB") == nil)
        #expect(try PairingStore.parse("").entries.isEmpty)
        #expect(throws: (any Error).self) { try PairingStore.parse("[1]") }
        #expect(try PairingStore.parse("{\"servers\":[null,{}, {\"token\":\"orphan\"}]}").entries.isEmpty)
        #expect(throws: (any Error).self) { try PairingStore.parse("{\"servers\":[{\"server_id\":\"id\",\"token\":\"t\",\"paired_ms\":1e100}]}") }
        #expect(PairingStore.deviceName("Meta Quest 3S") == "Quest 3S")
        #expect(PairingStore.deviceName("") == "Headset")
        #expect(PairingStore.deviceName("Apple Vision Pro") == "Apple Vision Pro")
        #expect(PairingStore.deviceName(String(repeating: "a", count: 50)).count == 32)
        var abstract: any TokenStorage = s
        #expect(try abstract.tokenFor(nil, "idA") == "tokC")
        #expect(try abstract.forget(nil, "idA"))
    }

    @Test func pairingMessages() throws {
        let m = try setupObject(setupFixture("pair_code"))
        let code = try #require(PairCode.from(m, 100))
        #expect(code.code == "482913" && code.spaced == "482 913" && code.required)
        #expect(code.secondsLeft(100) == 300 && code.live(399) && !code.live(400) && code.secondsLeft(401) == 0)
        for bad in ["48a913", "12345", "１２３４５６", "1234567"] {
            var m = m; m["code"] = .string(bad); #expect(PairCode.from(m, 0) == nil)
        }
        var short = m; short["expires_s"] = .number(0); short["token_rejected"] = .bool(true)
        #expect(PairCode.from(short, 10)?.secondsLeft(10) == 1)
        #expect(PairCode.from(short, 10)?.tokenRejected == true)
        let w = try PairingWelcome.from(setupObject(setupFixture("welcome_pair")))
        #expect(w.supported && w.paired && w.device == "a1b2c3d4" && w.serverId == "3f9c2a7e1b4d5c6a" && !w.required)
        #expect(PluginSupport.note(w, false) == nil)
        let old = try PairingWelcome.from(setupObject(setupFixture("welcome")))
        #expect(!old.supported)
        #expect(PluginSupport.note(old, false)?.contains("update it to v1.1.0") == true)
        #expect(PluginSupport.note(old, false)?.contains("textures") == true)
        #expect(PluginSupport.note(old, true)?.contains("textures") == false)
        #expect(PluginSupport.compare("1.10.0", "1.9.3") > 0)
        #expect(PluginSupport.compare("1.0.0", "1.1.0") < 0)
        #expect(PluginSupport.compare("1.1", "1.1.0") == 0)
        #expect(PluginSupport.compare("1.1.0-rc1", "1.1.0") == 0)
        #expect(PairingProtocol.request("Apple Vision Pro").s("type") == "pair_request")
        let paired = try setupObject(setupFixture("paired")), hello = try setupObject(setupFixture("hello_pair"))
        #expect(paired.s("token") == hello.s("device_token") && paired.s("server_id") == w.serverId)
    }

    @Test func addresses() {
        #expect(ServerAddress.normalize("192.168.1.50") == "ws://192.168.1.50:8765/tabletop")
        #expect(ServerAddress.normalize(" 192.168.1.50:8800 ") == "ws://192.168.1.50:8800/tabletop")
        #expect(ServerAddress.normalize("192.168.1.50:80") == "ws://192.168.1.50:80/tabletop")
        #expect(ServerAddress.normalize("WS://Host:9/x") == "ws://host:9/x")
        #expect(ServerAddress.normalize("wss://Host") == "wss://host:443/tabletop")
        #expect(ServerAddress.normalize("ws://Host") == "ws://host:80/tabletop")
        #expect(ServerAddress.normalize("mc-pc/") == "ws://mc-pc:8765/tabletop")
        for bad in ["", "a b", "http://x", "ws://", "1.2.3.4:99999", "1.2.3.4:0"] { #expect(ServerAddress.normalize(bad) == nil) }
        #expect(ServerAddress.hostOf("ws://192.168.1.50:8765/tabletop") == "192.168.1.50")
    }

    @Test func discoveryFixturesAndSubnets() throws {
        let probe = try setupObject(String(decoding: LanDiscovery.probe(), as: UTF8.self))
        #expect(probe.s("type") == "tabletop_discover" && probe.i("v") == 1)
        let f = try #require(LanDiscovery.parseReply(setupFixture("discovery_reply"), "192.168.1.50"))
        #expect(f.url == "ws://192.168.1.50:8765/tabletop" && f.name == "A Minecraft Server" && f.players == 2)
        #expect(!f.tokenNeeded && f.label == "A Minecraft Server (192.168.1.50)")
        #expect(f.id.isEmpty && !f.pair)
        let pair = try #require(LanDiscovery.parseReply(setupFixture("discovery_reply_pair"), "10.0.0.5"))
        #expect(pair.id == "3f9c2a7e1b4d5c6a" && pair.pair)
        var m = try setupObject(setupFixture("discovery_reply_pair")); m["token"] = .bool(true)
        #expect(try LanDiscovery.parseReply(Json.stringify(m), "10.0.0.5")?.label.contains("token") == false)
        for packet in ["nope", "[]", "{\"type\":\"other\",\"v\":1,\"port\":8765}", "{\"type\":\"tabletop_server\",\"v\":1,\"port\":0}"] {
            #expect(LanDiscovery.parseReply(packet, "10.0.0.5") == nil)
        }
        let hosts = LanDiscovery.targets("10.0.5.9")
        #expect(hosts.count == 254 && hosts.first == "10.0.5.1" && hosts.last == "10.0.5.254")
        #expect(!hosts.contains("10.0.5.255") && !hosts.contains("255.255.255.255"))
        #expect(LanDiscovery.targets(["10.0.5.9", "10.0.5.10", "192.168.7.23"]).count == 508)
        #expect(LanDiscovery.subnet24(nil).isEmpty && LanDiscovery.subnet24("::1").isEmpty)
        for ip in ["10.1.1.1", "172.16.0.1", "172.31.1.1", "192.168.0.1", "169.254.0.1"] { #expect(LanDiscovery.isPrivate(ip)) }
        for ip in ["172.15.1.1", "172.32.1.1", "8.8.8.8", "::1"] { #expect(!LanDiscovery.isPrivate(ip)) }
    }

    @Test func discoveryTransportAndFallback() async throws {
        let reply = try setupFixture("discovery_reply")
        let record = DiscoveryRecord()
        let udp = FixtureDiscoveryTransport(replies: [DiscoveryDatagram(data: Data(reply.utf8), senderHost: "10.0.0.5"),
                                                       DiscoveryDatagram(data: Data(reply.utf8), senderHost: "10.0.0.5")], record: record)
        let found = try await LanDiscovery.find(transport: udp)
        #expect(found.count == 1 && !found[0].portOnly)
        #expect(await record.tcpCount == 0)
        #expect(await record.targets.count == 508)
        #expect(await record.udpTimeout == 1200)
        let tcpRecord = DiscoveryRecord()
        let tcp = FixtureDiscoveryTransport(replies: [], record: tcpRecord)
        let fallback = try await LanDiscovery.find(transport: tcp)
        #expect(fallback.count == 1 && fallback[0].host == "10.0.0.5" && fallback[0].portOnly)
        #expect(await tcpRecord.tcpCount == 508)
        #expect(await tcpRecord.tcpTimeout == 400)
        #expect(await tcpRecord.maximum <= 48)
        let filtered = DiscoveryRecord()
        _ = try await LanDiscovery.probeUdp(["255.255.255.255", "10.0.0.255", "224.0.0.1", "127.0.0.1"], 8765, 50,
                                           transport: FixtureDiscoveryTransport(replies: [], record: filtered))
        #expect(await filtered.targets == ["127.0.0.1"])
    }
}

private actor DiscoveryRecord {
    var targets: [String] = []
    var udpTimeout = 0, tcpTimeout = 0, tcpCount = 0, active = 0, maximum = 0
    func udp(_ hosts: [String], _ timeout: Int) { targets = hosts; udpTimeout = timeout }
    func tcp(_ timeout: Int) { tcpCount += 1; tcpTimeout = timeout; active += 1; maximum = max(maximum, active) }
    func finished() { active -= 1 }
}
private struct FixtureDiscoveryTransport: LanDiscoveryTransport {
    let replies: [DiscoveryDatagram]
    let record: DiscoveryRecord
    func localIPv4() -> [String] { ["10.0.0.20", "192.168.7.20", "10.0.0.21"] }
    func probeUdp(_ probe: Data, targets: [String], port: Int, timeoutMs: Int, maxReplyBytes: Int) async throws -> [DiscoveryDatagram] {
        #expect(try setupObject(String(decoding: probe, as: UTF8.self)).s("type") == "tabletop_discover")
        #expect(port == 8765 && maxReplyBytes == 2048)
        await record.udp(targets, timeoutMs)
        return replies
    }
    func checkTcp(_ host: String, port: Int, timeoutMs: Int) async throws -> Bool {
        await record.tcp(timeoutMs)
        try await Task.sleep(for: .milliseconds(1))
        await record.finished()
        return host == "10.0.0.5"
    }
}

// Actual BSD transport coverage stays on loopback; it never scans the test runner's LAN.
extension SetupTests {
    @Test func bsdLoopbackProbeAndTcp() async throws {
        let udp = try boundLoopbackSocket(SOCK_DGRAM)
        defer { close(udp.fd) }
        let reply = try setupFixture("discovery_reply")
        let found = try await withThrowingTaskGroup(of: [FoundServer].self) { group in
            group.addTask {
                try await answerDiscovery(udp.fd, Data(reply.utf8))
                return []
            }
            group.addTask {
                try await LanDiscovery.probeUdp(["127.0.0.1"], udp.port, 200)
            }
            var found: [FoundServer] = []
            for try await result in group { found += result }
            return found
        }
        #expect(found.count == 1 && found.first?.url == "ws://127.0.0.1:8765/tabletop")
        let tcp = try boundLoopbackSocket(SOCK_STREAM)
        defer { close(tcp.fd) }
        #expect(listen(tcp.fd, 8) == 0)
        let open = await LanDiscovery.scanTcp(["127.0.0.1", "127.0.0.2"], tcp.port, 100)
        #expect(open.count == 1 && open.first?.host == "127.0.0.1" && open.first?.portOnly == true)
        #expect(open.first?.url == "ws://127.0.0.1:\(tcp.port)/tabletop")
        #expect(try await BSDDiscoveryTransport().checkTcp("255.255.255.255", port: tcp.port, timeoutMs: 100) == false)
    }
}
private func boundLoopbackSocket(_ type: Int32) throws -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw DiscoverySocketError(errno) }
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    } }
    guard bound == 0 else { let e = errno; close(fd); throw DiscoverySocketError(e) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
    } }
    guard named == 0 else { let e = errno; close(fd); throw DiscoverySocketError(e) }
    return (fd, Int(UInt16(bigEndian: a.sin_port)))
}
@concurrent private func answerDiscovery(_ fd: Int32, _ reply: Data) async throws {
    var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&event, 1, 1000) > 0 else { throw DiscoverySocketError(ETIMEDOUT) }
    var buffer = [UInt8](repeating: 0, count: 2048)
    var from = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let n = withUnsafeMutablePointer(to: &from) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
    } }
    guard n > 0 else { throw DiscoverySocketError(errno) }
    #expect(try setupObject(String(decoding: buffer.prefix(n), as: UTF8.self)).s("type") == LanDiscovery.probeType)
    for _ in 0..<2 {
        let sent = reply.withUnsafeBytes { bytes in withUnsafePointer(to: &from) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, length) }
        } }
        guard sent == reply.count else { throw DiscoverySocketError(errno) }
    }
}
