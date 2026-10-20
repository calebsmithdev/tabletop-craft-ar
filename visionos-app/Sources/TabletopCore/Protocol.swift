// Port of quest-app/Assets/Scripts/Net/Protocol.cs at 9ce237e.
import Foundation
import simd

public enum Protocol {
    public static let version = 1
    public static let clientName = "visionos-app"
    public static let clientVersion = "1.0.0"
    /// M1 stream, poses, snapshot extras, sections and pairing; no later feature capabilities.
    public static let capabilities = ["rle_palette_v1", "avatar", "light_v1", "biomes_v1", "sections_v1", "pair_v1"]
    public static let capLight = "light_v1", capBiomes = "biomes_v1"
    public static let capEdit = "edit_v1", capEntities = "entities_v1", capActions = "actions_v1"
    public static let capBlockEntities = "block_entities_v1", capWorld = "world_v1", capSound = "sound_v1"

    public static func hello(_ token: String? = nil, deviceToken: String? = nil,
                             deviceName: String? = "Apple Vision Pro", clientVersion: String = clientVersion) -> JSONObject {
        var d: JSONObject = ["type": "hello", "client": .string(clientName),
            "client_version": .string(clientVersion), "protocols": [.number(Double(version))],
            "token": .string(token ?? ""), "caps": .array(capabilities.map(JSONValue.string))]
        if let deviceToken, !deviceToken.isEmpty { d["device_token"] = .string(deviceToken) }
        if let deviceName, !deviceName.isEmpty { d["device_name"] = .string(deviceName) }
        return d
    }

    public static func subscribe(_ world: String, origin: Int3, dims: Int3) -> JSONObject {
        ["type": "subscribe", "world": .string(world), "origin": vector(origin), "dims": vector(dims)]
    }
    public static func avatarConfig(_ enabled: Bool, blockSizeM: Float, skinPlayer: String? = nil,
                                    showHands: Bool = true, nameTag: String? = nil) -> JSONObject {
        ["type": "avatar_config", "enabled": .bool(enabled), "block_size_m": .number(Double(String(blockSizeM)) ?? Double(blockSizeM)),
         "max_scale": 16, "skin_player": skinPlayer.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null,
         "show_hands": .bool(showHands), "name_tag": nameTag.map(JSONValue.string) ?? .null]
    }
    public static func regionRequest(_ world: String, center: Float3, size: Int3, yOrigin: Int? = nil) -> JSONObject {
        var d: JSONObject = ["type": "region_request", "world": .string(world),
            "center": .array((0..<3).map { .number(rounded(center[$0], places: 2)) }), "size": vector(size)]
        if let yOrigin { d["y_origin"] = .number(Double(yOrigin)) }
        return d
    }
    public static func regionRequest(_ world: String, origin: Int3, dims: Int3, viewMargin: Int3? = nil) -> JSONObject {
        var d = subscribe(world, origin: origin, dims: dims)
        d["type"] = "region_request"
        if let viewMargin { d["view_margin"] = vector(viewMargin) }
        return d
    }
    public static func regionQuery(_ player: String? = nil) -> JSONObject {
        var d: JSONObject = ["type": "region_query"]
        if let player, !player.isEmpty { d["player"] = .string(player) }
        return d
    }
    public static func blockEdit(_ op: String, pos: Int3, state: String? = nil, face: String? = nil) -> JSONObject {
        var d: JSONObject = ["type": "block_edit", "op": .string(op), "pos": vector(pos)]
        if let state { d["state"] = .string(state) }
        if let face { d["face"] = .string(face) }
        return d
    }
    public static func ping(_ id: Int) -> JSONObject { ["type": "ping", "id": .number(Double(id))] }
    public static func pong(_ ping: JSONObject) -> JSONObject {
        ["type": "pong", "id": .number(Double(ping.i("id"))), "echo_t": .number(ping.d("t"))]
    }
    public static func bye(_ reason: String) -> JSONObject { ["type": "bye", "reason": .string(reason)] }
    public static func error(_ code: String, message: String, refSeq: UInt32? = nil, fatal: Bool = false) -> JSONObject {
        var d: JSONObject = ["type": "error", "code": .string(code), "message": .string(message), "fatal": .bool(fatal)]
        if let refSeq { d["ref_seq"] = .number(Double(refSeq)) }
        return d
    }
    public static func pose(_ tsMicros: Int64, head: TabletopPose, left: TabletopPose? = nil,
                            right: TabletopPose? = nil, snapshotId: Int? = nil) -> JSONObject {
        var d: JSONObject = ["type": "pose", "ts": .number(Double(tsMicros)), "head": .object(head.toJson()),
            "left": left.map { .object($0.toJson()) } ?? .null, "right": right.map { .object($0.toJson()) } ?? .null]
        if let snapshotId { d["snapshot_id"] = .number(Double(snapshotId)) }
        return d
    }
    static func vector(_ v: Int3) -> JSONValue { .array((0..<3).map { .number(Double(v[$0])) }) }
    static func rounded(_ v: Float, places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (Double(v) * scale).rounded(.toNearestOrEven) / scale
    }
}

/// A per-connection uint32 envelope counter. A tracked send reserves its seq before transmission.
public struct Envelope: Sendable {
    public private(set) var nextSeq: UInt32
    public init(nextSeq: UInt32 = 0) { self.nextSeq = nextSeq }
    public mutating func reserve() -> UInt32 { let s = nextSeq; nextSeq &+= 1; return s }
    public mutating func wrap(_ body: JSONObject, seq: UInt32? = nil,
                              t: Double = Date().timeIntervalSince1970 * 1000) -> JSONObject {
        var d = body
        d["v"] = .number(Double(Protocol.version))
        d["seq"] = .number(Double(seq ?? reserve()))
        d["t"] = .number(t.rounded(.towardZero))
        return d
    }
}

/// Already in the right-handed tabletop frame: there is no Unity conversion here.
public struct TabletopPose: Sendable, Equatable {
    public var p: Float3
    public var q: SIMD4<Float>
    public var tracked: Bool
    // Wire poses may omit tracked:true. New poses keep the C# builder's explicit field.
    private var trackedPresent = true
    public init(p: Float3 = .zero, q: SIMD4<Float> = [0, 0, 0, 1], tracked: Bool = true) {
        self.p = p; self.q = q; self.tracked = tracked
    }
    public init(p: Float3, q: simd_quatf, tracked: Bool = true) { self.init(p: p, q: q.vector, tracked: tracked) }
    public func toJson() -> JSONObject {
        var result: JSONObject = ["p": .array((0..<3).map { .number(Protocol.rounded(p[$0], places: 4)) }),
                                  "q": .array((0..<4).map { .number(Protocol.rounded(q[$0], places: 5)) })]
        if trackedPresent || !tracked { result["tracked"] = .bool(tracked) }
        return result
    }
    public static func from(_ m: JSONObject) throws -> Self {
        let p = try Json.doubles(m.a("p")), q = try Json.doubles(m.a("q"))
        guard p.count == 3, q.count == 4, (p + q).allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) }) else {
            throw JsonError("bad pose")
        }
        var result = Self(p: Float3(Float(p[0]), Float(p[1]), Float(p[2])),
                          q: SIMD4(Float(q[0]), Float(q[1]), Float(q[2]), Float(q[3])), tracked: m.b("tracked", true))
        result.trackedPresent = m["tracked"] != nil
        return result
    }
}

public struct ChunkSnapshot: Sendable {
    public var snapshotId: Int
    public var world: String
    public var origin: Int3
    public var dims: Int3
    public var palette: [String]
    public var grid: [UInt16]
    public var light: [UInt8]?
    public var biomes: BiomeGrid?
    public init(snapshotId: Int = 0, world: String = "", origin: Int3 = .zero, dims: Int3 = .zero,
                palette: [String] = [], grid: [UInt16] = [], light: [UInt8]? = nil, biomes: BiomeGrid? = nil) {
        self.snapshotId = snapshotId; self.world = world; self.origin = origin; self.dims = dims
        self.palette = palette; self.grid = grid; self.light = light; self.biomes = biomes
    }
    /// maxBlocks is an allocation ceiling, always clamped to the client's hard cap.
    public static func from(_ m: JSONObject, maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> Self {
        guard m.s("order") == "yzx", m.s("encoding") == "rle_palette_v1" else { throw JsonError("unsupported order/encoding") }
        let origin = try SnapshotFields.vector(m, "origin"), dims = try SnapshotFields.vector(m, "dims")
        let volume = try SnapshotFields.volume(dims,maxBlocks: maxBlocks), palette = try SnapshotFields.strings(m, "palette")
        guard let world = m.s("world") else { throw JsonError("missing world") }
        for key in ["light", "biomes"] where m[key] != nil && m[key] != .null && m.o(key) == nil {
            throw JsonError("bad \(key)")
        }
        return try Self(snapshotId: SnapshotFields.integer(m, "snapshot_id"), world: world, origin: origin, dims: dims,
                        palette: palette, grid: decodeRle(m.a("data"), volume, palette.count,maxBlocks: maxBlocks),
                        light: decodeLight(m.o("light"), volume,maxBlocks: maxBlocks), biomes: BiomeGrid.from(m.o("biomes"),maxBlocks: maxBlocks))
    }
    public static func decodeRle(_ data: [JSONValue]?, _ volume: Int, _ paletteSize: Int,
                                 maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> [UInt16] {
        return try SnapshotFields.decode(data, volume, paletteSize,maxBlocks: maxBlocks)
    }
    public static func decodeRle(_ data: [JSONValue]?, volume: Int, paletteSize: Int,
                                 maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> [UInt16] {
        try decodeRle(data, volume, paletteSize,maxBlocks: maxBlocks)
    }
    public static func decodeLight(_ o: JSONObject?, _ volume: Int,
                                   maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> [UInt8]? {
        guard let o else { return nil }
        guard o.s("encoding") == "rle_v1" else { throw JsonError("unsupported light encoding") }
        return try decodeRle(o.a("data"), volume, 256,maxBlocks: maxBlocks).map(UInt8.init)
    }
}

public struct RegionLimits: Sendable, Equatable {
    public var maxX = 128, maxY = 384, maxZ = 128
    public var maxBlocks = 2_097_152, maxBytes = 4_194_304, maxViewWidth = 0
    public var buildHeight: [Int]?
    public static let `default` = Self()
    public init() {}
    public static func from(_ o: JSONObject?, _ fallback: Self = .default) -> Self {
        guard let o else { return fallback }
        var r = fallback
        if let a = o.a("max_dims"), let v = try? Json.ints(a), v.count == 3 { r.maxX = v[0]; r.maxY = v[1]; r.maxZ = v[2] }
        if o["max_blocks"] != nil { r.maxBlocks = o.i("max_blocks") }
        if o["max_bytes"] != nil { r.maxBytes = o.i("max_bytes") }
        if o["max_view_width"] != nil { r.maxViewWidth = o.i("max_view_width") }
        if let a = o.a("build_height"), let v = try? Json.ints(a), v.count == 2 { r.buildHeight = v }
        return r
    }
}

public struct RegionPlayer: Sendable {
    public var name: String?, uuid: String?, world: String?
    public var pos: Float3
    public var yaw: Float
    public static func from(_ o: JSONObject) throws -> Self {
        Self(name: o.s("name"), uuid: o.s("uuid"), world: o.s("world"), pos: try float3(o, "pos"), yaw: Float(o.d("yaw")))
    }
}

public struct RegionInfo: Sendable {
    public var world: String
    public var origin: Int3, dims: Int3, viewMargin: Int3
    public var limits: RegionLimits
    public var players: [RegionPlayer]
    public var refSeq: UInt32?
    public static func from(_ m: JSONObject) throws -> Self {
        guard let r = m.o("region"), let world = r.s("world") else { throw JsonError("missing region/world") }
        return try Self(world: world, origin: SnapshotFields.vector(r, "origin"), dims: SnapshotFields.vector(r, "dims"),
            viewMargin: r["view_margin"] == nil ? .zero : SnapshotFields.vector(r, "view_margin"),
            limits: RegionLimits.from(m.o("limits")), players: objects(m, "players").map(RegionPlayer.from), refSeq: reference(m))
    }
}

public struct RegionChanged: Sendable {
    public var world: String
    public var origin: Int3, dims: Int3, viewMargin: Int3
    public var limits: RegionLimits
    public var bySession: String?
    public var refSeq: UInt32?
    public static func from(_ m: JSONObject) throws -> Self {
        guard let world = m.s("world") else { throw JsonError("missing world") }
        return try Self(world: world, origin: SnapshotFields.vector(m, "origin"), dims: SnapshotFields.vector(m, "dims"),
            viewMargin: m["view_margin"] == nil ? .zero : SnapshotFields.vector(m, "view_margin"),
            limits: RegionLimits.from(m.o("limits")), bySession: m.s("by_session"), refSeq: reference(m))
    }
}

public struct Welcome: Sendable {
    public var `protocol`: Int
    public var server: String?, serverVersion: String?, mcVersion: String?, session: String?, serverId: String?
    public var world: String
    public var origin: Int3, dims: Int3, viewMargin: Int3
    public var limits: RegionLimits
    public var caps: [String]
    public var avatarSupported: Bool
    public var pairing: JSONObject?
    public static func from(_ m: JSONObject) throws -> Self {
        guard let r = m.o("region"), let world = m.s("world") else { throw JsonError("missing welcome region/world") }
        return try Self(protocol: SnapshotFields.integer(m, "protocol"), server: m.s("server"), serverVersion: m.s("server_version"),
            mcVersion: m.s("mc_version"), session: m.s("session"), serverId: m.s("server_id"), world: world,
            origin: SnapshotFields.vector(r, "origin"), dims: SnapshotFields.vector(r, "dims"),
            viewMargin: r["view_margin"] == nil ? .zero : SnapshotFields.vector(r, "view_margin"),
            limits: RegionLimits.from(m.o("limits")), caps: strings(m, "caps"), avatarSupported: m.b("avatar_supported"), pairing: m.o("pairing"))
    }
}

public struct ProtocolError: Sendable {
    public var code: String?, message: String?
    public var fatal: Bool
    public var refSeq: UInt32?
    public var limits: RegionLimits
    public var pos: Int3?
    public static func from(_ m: JSONObject) throws -> Self {
        try Self(code: m.s("code"), message: m.s("message"), fatal: m.b("fatal"), refSeq: reference(m),
                 limits: RegionLimits.from(m.o("limits") ?? m), pos: m["pos"] == nil ? nil : SnapshotFields.vector(m, "pos"))
    }
}

public struct BlockUpdate: Sendable {
    public struct Change: Sendable, Equatable { public var pos: Int3; public var value: Int }
    public var snapshotId: Int
    public var paletteAdd: [String]
    public var changes: [Change]
    public var light: [Change]
    public static func from(_ m: JSONObject) throws -> Self {
        func changes(_ key: String) throws -> [Change] {
            try (m.a(key) ?? []).map {
                let a = try Json.ints($0.arrayValue)
                guard a.count == 4, a.allSatisfy({ $0 >= 0 }) else { throw JsonError("bad \(key)") }
                return Change(pos: Int3(a[0], a[1], a[2]), value: a[3])
            }
        }
        return try Self(snapshotId: SnapshotFields.integer(m, "snapshot_id"), paletteAdd: strings(m, "palette_add"),
                        changes: changes("changes"), light: changes("light"))
    }
}

public struct PlayerInfo: Sendable {
    public var uuid: String?, name: String?, skin: String?, skinModel: String?
    public var hasSkin: Bool
    public var pos: Float3
    public var yaw: Float, pitch: Float
    public var sneaking: Bool
    public var id: Int, vehicle: Int
    public var pose: String?
    public var equipment: [String: String]
    public static func from(_ p: JSONObject) throws -> Self {
        Self(uuid: p.s("uuid"), name: p.s("name"), skin: p.s("skin"), skinModel: p.s("skin_model"), hasSkin: p["skin"] != nil,
             pos: try float3(p, "pos"), yaw: Float(p.d("yaw")), pitch: Float(p.d("pitch")), sneaking: p.b("sneaking"),
             id: p.i("id", -1), vehicle: p.i("vehicle", -1), pose: p.s("pose"),
             equipment: (p.o("equipment") ?? [:]).compactMapValues(\.stringValue))
    }
}

public struct AvatarState: Sendable {
    public var enabled: Bool, skinResolved: Bool
    public var entityUuid: String?, note: String?
    public var scale: Double, worldHeightBlocks: Double
    public var debug: JSONObject?
    public static func from(_ m: JSONObject) -> Self {
        Self(enabled: m.b("enabled"), skinResolved: m.b("skin_resolved"), entityUuid: m.s("entity_uuid"), note: m.s("note"),
             scale: m.d("scale"), worldHeightBlocks: m.d("world_height_blocks"), debug: m.o("debug"))
    }
}

private func float3(_ m: JSONObject, _ key: String) throws -> Float3 {
    let a = try Json.doubles(m.a(key))
    guard a.count == 3, a.allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) }) else { throw JsonError("bad \(key)") }
    return Float3(Float(a[0]), Float(a[1]), Float(a[2]))
}
private func reference(_ m: JSONObject) -> UInt32? { m["ref_seq"]?.numberValue.flatMap(UInt32.init(exactly:)) }
private func strings(_ m: JSONObject, _ key: String) -> [String] { (m.a(key) ?? []).compactMap(\.stringValue) }
private func objects(_ m: JSONObject, _ key: String) throws -> [JSONObject] {
    try (m.a(key) ?? []).map { guard let o = $0.objectValue else { throw JsonError("bad \(key)") }; return o }
}
