import Foundation
import TabletopCore

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case invalidFixture(String)

    var description: String {
        switch self {
        case .usage(let message), .invalidFixture(let message): message
        }
    }
}

@main
struct TabletopCLI {
    static let usage = """
    tabletop-cli --fixture <message.json>
    tabletop-cli --mesh <snapshot.json> [--hash]
    tabletop-cli --live ws://HOST:8765/tabletop [--token T] [--seconds N]

    Delta fixtures load their base from chunk_snapshot_sections.json beside the input.
    """

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String]) async throws {
        if args == ["--help"] { print(usage); return }
        guard args.count >= 2 else { throw CLIError.usage(usage) }
        switch args[0] {
        case "--fixture":
            guard args.count == 2 else { throw CLIError.usage(usage) }
            let start = ContinuousClock.now
            let messages = try readMessages(URL(fileURLWithPath: args[1]))
            print("messages=\(messages.count)")
            for message in messages {
                print("type=\(message.s("type") ?? "-") seq=\(message.i("seq"))")
                try describe(message)
            }
            if messages.first?.s("type") == "chunk_snapshot" {
                let snapshot = try loadSnapshot(URL(fileURLWithPath: args[1]))
                summarize(snapshot)
                print(String(format: "decode_ms=%.3f", milliseconds(since: start)))
            }
        case "--mesh":
            guard args.count == 2 || (args.count == 3 && args[2] == "--hash") else {
                throw CLIError.usage(usage)
            }
            try mesh(URL(fileURLWithPath: args[1]), hash: args.contains("--hash"))
        case "--live":
            var token = ""
            var seconds = 10.0
            var index = 2
            while index < args.count {
                guard index + 1 < args.count else { throw CLIError.usage(usage) }
                switch args[index] {
                case "--token": token = args[index + 1]
                case "--seconds":
                    guard let value = Double(args[index + 1]), value.isFinite, value > 0 else {
                        throw CLIError.usage("--seconds must be a positive finite number")
                    }
                    seconds = value
                default: throw CLIError.usage(usage)
                }
                index += 2
            }
            try await live(args[1], token: token, seconds: seconds)
        default: throw CLIError.usage(usage)
        }
    }

    static func describe(_ message: JSONObject) throws {
        switch message.s("type") {
        case "welcome":
            let welcome = try Welcome.from(message)
            print("server=\(welcome.server ?? "-") world=\(welcome.world) dims=\(welcome.dims) caps=\(welcome.caps.joined(separator: ","))")
        case "region_info":
            let info = try RegionInfo.from(message)
            print("world=\(info.world) origin=\(info.origin) dims=\(info.dims) players=\(info.players.count)")
        case "region_changed":
            let info = try RegionChanged.from(message)
            print("world=\(info.world) origin=\(info.origin) dims=\(info.dims)")
        case "block_update":
            let update = try BlockUpdate.from(message)
            print("snapshot=\(update.snapshotId) palette_add=\(update.paletteAdd.count) changes=\(update.changes.count) light_changes=\(update.light.count)")
        case "player_positions":
            let players = try (message.a("players") ?? []).map { value in
                guard let player = value.objectValue else { throw CLIError.invalidFixture("player must be an object") }
                return try PlayerInfo.from(player)
            }
            print("players=\(players.count) names=\(players.compactMap(\.name).joined(separator: ","))")
        case "pose":
            guard let head = message.o("head") else { throw CLIError.invalidFixture("pose requires head") }
            let pose = try TabletopPose.from(head)
            print("head_p=\(pose.p) head_q=\(pose.q) tracked=\(pose.tracked)")
        case "avatar_state":
            let state = AvatarState.from(message)
            print("enabled=\(state.enabled) scale=\(state.scale) skin_resolved=\(state.skinResolved)")
        case "pair_code":
            guard let code = PairCode.from(message, 0) else { throw CLIError.invalidFixture("invalid pair_code") }
            print("code=\(code.spaced) expires_s=\(code.secondsLeft(0)) required=\(code.required)")
        case "error":
            let error = try ProtocolError.from(message)
            print("code=\(error.code ?? "-") fatal=\(error.fatal) message=\(error.message ?? "-")")
        default: break
        }
    }

    static func readMessages(_ url: URL) throws -> [JSONObject] {
        let json = try Json.parse(String(contentsOf: url, encoding: .utf8))
        switch json {
        case .object(let message): return [message]
        case .array(let parts):
            return try parts.map {
                guard case .object(let message) = $0 else {
                    throw CLIError.invalidFixture("snapshot part must be an object")
                }
                return message
            }
        default: throw CLIError.invalidFixture("fixture must be an object or array of snapshot parts")
        }
    }

    static func loadSnapshot(_ url: URL) throws -> ChunkSnapshot {
        let messages = try readMessages(url)
        guard let first = messages.first, first.s("type") == "chunk_snapshot" else {
            throw CLIError.invalidFixture("expected chunk_snapshot")
        }
        if first.s("encoding") != SectionedSnapshot.encoding {
            return try ChunkSnapshot.from(first)
        }
        var world = WorldModel()
        if first.o("base") != nil {
            let baseURL = url.deletingLastPathComponent().appendingPathComponent("chunk_snapshot_sections.json")
            guard baseURL.standardizedFileURL != url.standardizedFileURL else {
                throw CLIError.invalidFixture("delta requires its base snapshot")
            }
            world.applySnapshot(try loadSnapshot(baseURL))
        }
        var listed: [Int3] = []
        return try SectionedSnapshot.assemble(messages, current: world, listed: &listed)
    }

    static func summarize(_ snapshot: ChunkSnapshot) {
        let d = snapshot.dims
        print("snapshot=\(snapshot.snapshotId) world=\(snapshot.world) dims=\(d.x)x\(d.y)x\(d.z) palette=\(snapshot.palette.count) RLE_total=\(snapshot.grid.count) volume=\(d.x * d.y * d.z)")
        for coordinate in [Int3.zero, Int3(d.x / 2, d.y / 2, d.z / 2),
                           Int3(d.x / 2, d.y * 3 / 4, d.z / 2), Int3(d.x - 1, d.y - 1, d.z - 1)] {
            let index = (coordinate.y * d.z + coordinate.z) * d.x + coordinate.x
            print("block[\(coordinate.x),\(coordinate.y),\(coordinate.z)]=\(snapshot.palette[Int(snapshot.grid[index])])")
        }
    }

    static func mesh(_ url: URL, hash: Bool) throws {
        let decodeStart = ContinuousClock.now
        let snapshot = try loadSnapshot(url)
        let decodeMs = milliseconds(since: decodeStart)
        summarize(snapshot)
        var world = WorldModel()
        world.applySnapshot(snapshot)
        let n = world.sectionCount
        var meshMs = 0.0
        var vertices = 0
        var faces = 0
        var meshes: [MeshData] = []
        for x in 0..<n.x {
            for y in 0..<n.y {
                for z in 0..<n.z {
                    let section = Int3(x, y, z)
                    var data = MeshData()
                    let start = ContinuousClock.now
                    GreedyMesher.build(world, section, &data)
                    GreedyMesher.buildSpecials(world, section, &data)
                    meshMs += milliseconds(since: start)
                    vertices += data.verts.count
                    faces += data.verts.count / 4
                    print("section=\(x),\(y),\(z) faces=\(data.verts.count / 4) vertices=\(data.verts.count)")
                    if hash {
                        print("section_hash_exact=\(MeshHash.exact(data))")
                        meshes.append(data)
                    }
                }
            }
        }
        print(String(format: "sections=%d faces=%d vertices=%d decode_ms=%.3f mesh_ms=%.3f",
                     n.x * n.y * n.z, faces, vertices, decodeMs, meshMs))
        if hash { print("canonical_quad_hash=\(MeshHash.canonical(meshes))") }
    }

    static func live(_ url: String, token: String, seconds: Double) async throws {
        let link = LinkClient(url: url, token: token)
        await link.start()
        var world = WorldModel()
        var assembler = SnapshotAssembler()
        let start = ContinuousClock.now
        var previousRTT = -1.0
        var previousStatus = ""
        do {
        while milliseconds(since: start) < seconds * 1_000 {
            let status = await link.status
            if status != previousStatus { print("link: \(status)"); previousStatus = status }
            for message in await link.drain() {
                switch message.s("type") {
                case "welcome":
                    print("welcome server=\(message.s("server") ?? "-") version=\(message.s("server_version") ?? "-") world=\(message.s("world") ?? "-")")
                case "chunk_snapshot":
                    try assembler.offer(message, world, [])
                    if let result = assembler.wait() {
                        if let snapshot = result.snapshot {
                            world.applySnapshot(snapshot)
                            summarize(snapshot)
                        } else {
                            print("bad_snapshot: \(result.error ?? "unknown error")")
                            var error = Protocol.error("bad_snapshot", message: result.error ?? "snapshot could not be assembled",
                                                       refSeq: message["seq"]?.numberValue.flatMap(UInt32.init(exactly:)))
                            error["snapshot_id"] = .number(Double(result.snapshotId))
                            await link.send(error)
                        }
                    }
                case "block_update":
                    let applied = world.applyBlockUpdate(message)
                    print("block_update snapshot=\(message.i("snapshot_id")) changes=\(message.a("changes")?.count ?? 0) applied=\(applied)")
                case "error": print("server error \(message.s("code") ?? "-"): \(message.s("message") ?? "-")")
                case "pair_code": print("pair_code \(message.s("code") ?? "-") expires_s=\(message.i("expires_s"))")
                case "paired":
                    await link.setDeviceToken(message.s("token"))
                    print("paired device=\(message.s("device") ?? "-")")
                case "bye": print("server bye: \(message.s("reason") ?? "-")")
                default: break
                }
            }
            let rtt = await link.rttMs
            if rtt >= 0 && rtt != previousRTT {
                print("RTT_ms=\(rtt)")
                previousRTT = rtt
            }
            if await link.fatalCode != 0 {
                await link.stop()
                throw CLIError.invalidFixture(await link.fatalReason)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        } catch {
            await link.stop(reason: "CLI error")
            throw error
        }
        await link.stop(reason: "CLI session complete")
        print("bye: CLI session complete")
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
}
