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
    tabletop-cli --mesh <snapshot.json> [--jar <jar>] [--hash] [--flat-light | --no-light] [--reference-profile] [--reps N]
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
            var jar: String?, dump: String?, hash = false, flatLight = false, noLight = false, reference = false, reps = 1
            var index = 2
            while index < args.count {
                switch args[index] {
                case "--hash": hash = true
                case "--flat-light": flatLight = true
                case "--no-light": noLight = true
                case "--reference-profile": reference = true
                case "--jar", "--dump", "--reps":
                    guard index+1 < args.count else { throw CLIError.usage(usage) }
                    let option = args[index]; index += 1
                    if option == "--jar" { jar = args[index] }
                    else if option == "--dump" { dump = args[index] }
                    else { guard let value = Int(args[index]), (1...1000).contains(value) else { throw CLIError.usage("--reps must be 1...1000") }; reps = value }
                default: throw CLIError.usage(usage)
                }
                index += 1
            }
            try mesh(URL(fileURLWithPath: args[1]),hash: hash,jar: jar,flatLight: flatLight,noLight: noLight,referenceProfile: reference,reps: reps,dump: dump)
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

    static func mesh(_ url: URL, hash: Bool, jar: String?, flatLight: Bool, noLight: Bool, referenceProfile: Bool, reps: Int, dump: String?) throws {
        let decodeStart = ContinuousClock.now
        let snapshot = try loadSnapshot(url)
        let decodeMs = milliseconds(since: decodeStart)
        summarize(snapshot)
        var world = WorldModel(); world.applySnapshot(snapshot)
        if noLight { world.light = nil; world.biomes = nil; world.tints = nil }
        world.shading = BlockShading(smoothLighting: !flatLight)
        var faces: any IFaceSource = FlatFaceSource()
        var solidLayers: Set<Int> = []
        if let jar {
            let loadStart = ContinuousClock.now
            let atlas = try ResourcePackAtlas(path: jar,referenceProfile: referenceProfile)
            let loadMs = milliseconds(since: loadStart), bakeStart = ContinuousClock.now
            atlas.prewarm(world.palette)
            if referenceProfile {
                _ = atlas.face(FluidRules.waterState,0); _ = atlas.face(FluidRules.lavaState,0)
                // The C# profile resolves these lazily in the untimed warm-up. They have no baked
                // geometry in PackFaces; resolve before publishing our immutable worker snapshot.
                _ = atlas.face(FluidRules.waterFlowState,4); _ = atlas.face(FluidRules.lavaFlowState,4)
                _ = atlas.face(FluidRules.overlayState,4)
            }
            let pack = atlas.baked(), bakeMs = milliseconds(since: bakeStart)
            world.applyShapeOverrides(pack.shapeOverrides)
            if !noLight { world.setColormaps(pack.colormaps) }
            faces = pack; solidLayers = pack.solidLayers
            print(String(format: "pack_load_ms=%.3f pack_bake_ms=%.3f layers=%d animations=%d tile=%d reference_profile=%@",loadMs,bakeMs,pack.layers.count,pack.animations.count,pack.tileSize,referenceProfile ? "yes" : "no"))
        }
        let n = world.sectionCount
        let sections = (0..<n.x).flatMap { x in (0..<n.y).flatMap { y in (0..<n.z).map { Int3(x,y,$0) } } }
        // Like the C# runner, measure after one untimed pass.
        for section in sections {
            var data = MeshData(); GreedyMesher.build(world,section,faces,&data)
            GreedyMesher.buildSpecials(world,section,faces,&data)
            _ = SectionMesh.from(data,section,solidLayers: solidLayers)
        }
        if let dump { try FileManager.default.createDirectory(atPath: dump,withIntermediateDirectories: true) }
        var meshMs = 0.0, fromMs = 0.0, vertices = 0, quads = 0
        var meshes: [MeshData] = []
        for repetition in 0..<reps {
            for section in sections {
                var data = MeshData(); let start = ContinuousClock.now
                GreedyMesher.build(world,section,faces,&data)
                GreedyMesher.buildSpecials(world,section,faces,&data)
                meshMs += milliseconds(since: start)
                let fromStart = ContinuousClock.now
                let sectionMesh = SectionMesh.from(data,section,solidLayers: solidLayers)
                fromMs += milliseconds(since: fromStart)
                if repetition == 0 {
                    vertices += data.verts.count; quads += sectionMesh?.quads ?? 0
                    print("section=\(section.x),\(section.y),\(section.z) faces=\(sectionMesh?.quads ?? 0) vertices=\(data.verts.count)")
                    if hash { print("section_hash_exact=\(MeshHash.exact(data))"); meshes.append(data) }
                    if let dump { try dumpMesh(data,to: URL(fileURLWithPath: dump).appendingPathComponent("\(section.x)-\(section.y)-\(section.z).json")) }
                }
            }
        }
        let count = max(1,sections.count*reps)
        print(String(format: "sections=%d faces=%d vertices=%d decode_ms=%.3f mesh_ms=%.3f from_ms=%.3f mesh_ms_per_section=%.3f total_ms_per_section=%.3f reps=%d",sections.count,quads,vertices,decodeMs,meshMs/Double(reps),fromMs/Double(reps),meshMs/Double(count),(meshMs+fromMs)/Double(count),reps))
        if hash { print("canonical_quad_hash=\(MeshHash.canonical(meshes))") }
    }

    static func dumpMesh(_ mesh: MeshData, to url: URL) throws {
        func bits(_ vectors: [SIMD3<Float>]) -> [[Int32]] {
            vectors.map { [Int32(bitPattern: $0.x.bitPattern),Int32(bitPattern: $0.y.bitPattern),Int32(bitPattern: $0.z.bitPattern)] }
        }
        let value: [String:Any] = ["verts":bits(mesh.verts),"uvs":bits(mesh.uvs),"colors":mesh.colors.map { [Int($0.r),Int($0.g),Int($0.b),Int($0.a)] },"opaque":mesh.opaque,"transparent":mesh.transparent,"waterBack":mesh.waterBack,"light":mesh.light.map(Int.init)]
        try JSONSerialization.data(withJSONObject: value,options: [.sortedKeys]).write(to: url)
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
