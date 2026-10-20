// Ported from quest-app/Assets/Scripts/World/AppPrefs.cs @ 9ce237e.
import Foundation

public struct TablePose: Sendable, Equatable {
    public var x: Float = 0, y: Float = 0, z: Float = 0, yaw: Float = 0
    public init(x: Float = 0, y: Float = 0, z: Float = 0, yaw: Float = 0) {
        self.x = x; self.y = y; self.z = z; self.yaw = yaw
    }
    public static func relative(_ refPos: Float3, _ refYaw: Float, _ pos: Float3, _ yaw: Float) -> TablePose {
        let d = rotY(pos - refPos, -refYaw)
        return TablePose(x: d.x, y: d.y, z: d.z, yaw: wrap(yaw - refYaw))
    }
    public func compose(_ refPos: Float3, _ refYaw: Float) -> (pos: Float3, yaw: Float) {
        (refPos + Self.rotY(Float3(x, y, z), refYaw), Self.wrap(refYaw + yaw))
    }
    // Rotation about +Y in the protocol's right-handed frame; no Z reflection.
    public static func rotY(_ v: Float3, _ deg: Float) -> Float3 {
        let a = Double(deg) * .pi / 180, c = cos(a), s = sin(a)
        return Float3(Float(Double(v.x) * c + Double(v.z) * s), v.y,
                      Float(-Double(v.x) * s + Double(v.z) * c))
    }
    public static func wrap(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

public struct AppPrefs: Sendable {
    public static let fileName = "prefs.json"
    public static let version = 1
    public static let sharedKeys = ["block_size_m", "area_width", "show_hud", "volume", "sound"]
    public var server: String?
    public var meshWorkers = 3
    public var blockSizeM: Float?
    public var areaWidth = 0
    public var showHud: Bool?
    public var volume: Float?
    public var sound: Bool?
    public var menuTab: String?
    public var hotbar: [String?]?
    public var hotbarSelected = 0
    public var selected: String?
    public var tableAnchor: String?
    public var table: TablePose?
    public var chatSafety: JSONObject?
    public private(set) var seen: JSONObject = [:]
    public init() {}

    public static func parse(_ json: String) throws -> AppPrefs {
        var p = AppPrefs()
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return p }
        guard case .object(let m) = try Json.parse(json) else { throw PrefsError.notObject(fileName) }
        if case .number(let bs) = m["block_size_m"], bs > 0 { p.blockSizeM = Float(bs) }
        p.server = m.s("server")
        p.meshWorkers = max(1, min(8, m.i("mesh_workers", 3)))
        p.areaWidth = max(0, m.i("area_width"))
        if case .bool(let h) = m["show_hud"] { p.showHud = h }
        if case .number(let v) = m["volume"] { p.volume = Float(max(0, min(1, v))) }
        if case .bool(let s) = m["sound"] { p.sound = s }
        p.menuTab = m.s("menu_tab")
        p.hotbar = m.a("hotbar")?.prefix(9).map { if case .string(let s) = $0 { return s }; return nil }
        p.hotbarSelected = m.i("hotbar_selected")
        p.selected = m.s("selected")
        if let t = m.o("table"), let pos = t.a("pos"), pos.count == 3,
           let anchor = t.s("anchor"), !anchor.isEmpty {
            let v = try Json.doubles(pos)
            p.tableAnchor = anchor
            p.table = TablePose(x: Float(v[0]), y: Float(v[1]), z: Float(v[2]), yaw: Float(t.d("yaw")))
        }
        p.chatSafety = m.o("chat_safety")
        p.seeConfig(m.o("tabletop_json"))
        return p
    }
    public func toJson() throws -> String {
        func rounded(_ v: Float, _ digits: Double) -> JSONValue {
            .number((Double(v) * digits).rounded(.toNearestOrEven) / digits)
        }
        var d: JSONObject = ["v": .number(Double(Self.version))]
        if let server, !server.isEmpty { d["server"] = .string(server) }
        d["mesh_workers"] = .number(Double(meshWorkers))
        if let v = blockSizeM { d["block_size_m"] = rounded(v, 1_000_000) }
        if areaWidth > 0 { d["area_width"] = .number(Double(areaWidth)) }
        if let v = showHud { d["show_hud"] = .bool(v) }
        if let v = volume { d["volume"] = rounded(v, 100) }
        if let v = sound { d["sound"] = .bool(v) }
        if let v = menuTab, !v.isEmpty { d["menu_tab"] = .string(v) }
        if let hotbar {
            d["hotbar"] = .array(hotbar.map { $0.map(JSONValue.string) ?? .null })
            d["hotbar_selected"] = .number(Double(hotbarSelected))
        }
        if let selected, !selected.isEmpty { d["selected"] = .string(selected) }
        if let t = table, let anchor = tableAnchor, !anchor.isEmpty {
            d["table"] = .object(["anchor": .string(anchor), "pos": .array([rounded(t.x, 10_000), rounded(t.y, 10_000), rounded(t.z, 10_000)]), "yaw": rounded(t.yaw, 100)])
        }
        if let chatSafety, !chatSafety.isEmpty { d["chat_safety"] = .object(chatSafety) }
        if !seen.isEmpty { d["tabletop_json"] = .object(seen) }
        return try ConfigFile.pretty(d)
    }
    public static func pick(_ json: JSONValue?, _ prefs: JSONValue?, _ seen: JSONValue?) -> JSONValue? {
        let json = json == .null ? nil : json
        let prefs = prefs == .null ? nil : prefs
        let seen = seen == .null ? nil : seen
        if let json, json != seen { return json }
        return prefs ?? json
    }
    public mutating func seeConfig(_ tabletopJson: JSONObject?) {
        seen.removeAll()
        for key in Self.sharedKeys {
            guard let v = tabletopJson?[key] else { continue }
            switch v { case .number, .bool: seen[key] = v; default: break }
        }
    }
    // The caller chooses the application-support directory; no global paths or UI dependencies.
    public static func load(from directory: URL) throws -> AppPrefs {
        let file = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: file.path) { return AppPrefs() }
        return try parse(String(contentsOf: file, encoding: .utf8))
    }
    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try toJson().write(to: directory.appendingPathComponent(Self.fileName), atomically: true, encoding: .utf8)
    }
}

public enum PrefsError: Error, Sendable { case notObject(String) }

public struct PrefsSaver: Sendable {
    public var quiet = 1.5, maxDelay = 10.0
    private var savedText: String?, pending: String?
    private var since = 0.0, first = 0.0
    public init() {}
    public mutating func saved(_ json: String) { savedText = json; pending = nil }
    public mutating func offer(_ json: String?, _ now: Double) -> String? {
        guard let json, json != savedText else { pending = nil; return nil }
        if json != pending {
            if pending == nil { first = now }
            pending = json; since = now
        }
        return now - since >= quiet || now - first >= maxDelay ? pending : nil
    }
    public func flush(_ json: String?) -> String? { json != savedText ? json : nil }
}

public enum ConfigFile {
    public static let fileName = "tabletop.json"
    public static func withServer(_ oldJson: String?, _ url: String) throws -> String {
        var d: JSONObject = [:]
        if let oldJson, !oldJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard case .object(let m) = try Json.parse(oldJson) else { throw PrefsError.notObject(fileName) }
            d = m
        }
        d["server"] = .string(url)
        return try pretty(d)
    }
    public static func pretty(_ d: JSONObject) throws -> String {
        // Stable ordering also makes debouncing independent of dictionary iteration order.
        "{\n" + (try d.keys.sorted().map { "  \(try Json.stringify(.string($0))): \(try Json.stringify(d[$0]!))" }).joined(separator: ",\n") + "\n}\n"
    }
}
