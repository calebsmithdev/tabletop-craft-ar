// Ported from quest-app/Assets/Scripts/Net/Pairing.cs @ 6017fc2.
import Foundation

public struct PairingEntry: Sendable, Equatable {
    public var serverId = "", url = "", token = "", device = "", name = ""
    public var pairedMs: Int64 = 0
    public init(serverId: String = "", url: String = "", token: String = "", device: String = "",
                name: String = "", pairedMs: Int64 = 0) {
        self.serverId = serverId; self.url = url; self.token = token; self.device = device
        self.name = name; self.pairedMs = pairedMs
    }
}

// A production Keychain adapter can implement this without persisting tokens in prefs.json.
public protocol TokenStorage: Sendable {
    func find(_ url: String?, _ serverId: String?) throws -> PairingEntry?
    mutating func save(_ serverId: String?, _ url: String?, _ token: String, _ device: String?, _ name: String?, _ nowMs: Int64) throws
    @discardableResult mutating func seen(_ url: String?, _ serverId: String?) throws -> Bool
    @discardableResult mutating func forget(_ url: String?, _ serverId: String?) throws -> Bool
}

// Memory implementation, with the C# JSON import/export for parity and migration only.
// It never writes tokens to disk. The app should inject a Keychain TokenStorage adapter.
public struct PairingStore: TokenStorage, Sendable {
    public static let fileName = "pairings.json"
    public private(set) var entries: [PairingEntry] = []
    public init() {}
    public static func parse(_ json: String) throws -> PairingStore {
        var s = PairingStore()
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        guard case .object(let m) = try Json.parse(json) else { throw PrefsError.notObject(fileName) }
        for value in m.a("servers") ?? [] {
            guard case .object(let e) = value else { continue }
            guard let pairedMs = Int64(exactly: e.d("paired_ms").rounded(.towardZero)) else {
                throw JsonError("paired_ms is outside Int64 range")
            }
            let p = PairingEntry(serverId: e.s("server_id") ?? "", url: e.s("url") ?? "", token: e.s("token") ?? "",
                                 device: e.s("device") ?? "", name: e.s("name") ?? "", pairedMs: pairedMs)
            if !p.token.isEmpty && (!p.serverId.isEmpty || !p.url.isEmpty) { s.entries.append(p) }
        }
        return s
    }
    public func toJson() throws -> String {
        let list: [JSONValue] = entries.map { e in .object([
            "server_id": .string(e.serverId), "url": .string(e.url), "token": .string(e.token),
            "device": .string(e.device), "name": .string(e.name), "paired_ms": .number(Double(e.pairedMs))]) }
        return try Json.stringify(.object(["v": .number(1), "servers": .array(list)])) + "\n"
    }
    public func find(_ url: String?, _ serverId: String?) -> PairingEntry? {
        if let serverId, !serverId.isEmpty, let e = entries.first(where: { $0.serverId == serverId }) { return e }
        if let url, !url.isEmpty { return entries.first { $0.url == url } }
        return nil
    }
    public func tokenFor(_ url: String?, _ serverId: String?) -> String? { find(url, serverId)?.token }
    public mutating func save(_ serverId: String?, _ url: String?, _ token: String, _ device: String?, _ name: String?, _ nowMs: Int64) {
        forget(url, serverId)
        entries.append(PairingEntry(serverId: serverId ?? "", url: url ?? "", token: token,
                                    device: device ?? "", name: name ?? "", pairedMs: nowMs))
    }
    @discardableResult public mutating func seen(_ url: String?, _ serverId: String?) -> Bool {
        guard let serverId, !serverId.isEmpty, let url, !url.isEmpty,
              let i = entries.firstIndex(where: { $0.serverId == serverId }), entries[i].url != url else { return false }
        entries[i].url = url
        return true
    }
    @discardableResult public mutating func forget(_ url: String?, _ serverId: String?) -> Bool {
        let count = entries.count
        entries.removeAll { e in
            (serverId?.isEmpty == false && e.serverId == serverId) || (url?.isEmpty == false && e.url == url)
        }
        return entries.count != count
    }
    public static func deviceName(_ model: String?) -> String {
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for name in ["Quest 3S", "Quest 3", "Quest Pro", "Quest"] {
            if m.range(of: name, options: .caseInsensitive) != nil { return name }
        }
        return m.isEmpty ? "Headset" : String(m.prefix(32))
    }
}
public typealias MemoryTokenStorage = PairingStore

public extension TokenStorage {
    func tokenFor(_ url: String?, _ serverId: String?) throws -> String? { try find(url, serverId)?.token }
}

public struct PairCode: Sendable, Equatable {
    public var code = ""
    public var expiresAt = 0.0
    public var required = false, tokenRejected = false
    public init() {}
    public static func from(_ m: JSONObject, _ now: Double) -> PairCode? {
        let code = m.s("code") ?? ""
        guard code.utf8.count == 6, code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        var c = PairCode()
        c.code = code; c.expiresAt = now + Double(max(1, m.i("expires_s", 300)))
        c.required = m.b("required"); c.tokenRejected = m.b("token_rejected")
        return c
    }
    public func live(_ now: Double) -> Bool { now < expiresAt }
    public func secondsLeft(_ now: Double) -> Int {
        let remaining = ceil(expiresAt - now)
        if remaining.isNaN || remaining <= 0 { return 0 }
        return Int(exactly: remaining) ?? Int.max
    }
    public var spaced: String { code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code }
}

public struct PairingWelcome: Sendable, Equatable {
    public var supported = false, paired = false, required = false, tokenRejected = false
    public var serverId = "", device = "", name = "", serverVersion = ""
    public init() {}
    public static func from(_ welcome: JSONObject) -> PairingWelcome {
        var w = PairingWelcome()
        w.serverId = welcome.s("server_id") ?? ""; w.serverVersion = welcome.s("server_version") ?? ""
        guard let p = welcome.o("pairing") else { return w }
        w.supported = true; w.paired = p.b("paired"); w.required = p.b("required")
        w.tokenRejected = p.b("token_rejected"); w.device = p.s("device") ?? ""; w.name = p.s("name") ?? ""
        return w
    }
}

public enum PluginSupport {
    public static let releases = "github.com/NickStassen/tabletop-craft-ar/releases"
    public static let pairingSince = "1.1.0"
    public static func note(_ w: PairingWelcome, _ hasPack: Bool) -> String? {
        if w.supported { return nil }
        let v = w.serverVersion.isEmpty ? "an older version" : named(w.serverVersion)
        return "Server plugin \(v) can't pair headsets\(hasPack ? "" : " or send the game's textures"): "
            + "update it to \(named(pairingSince)) or newer (\(releases))"
    }
    public static func named(_ version: String) -> String { version.isEmpty || version.hasPrefix("v") ? version : "v" + version }
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] {
            let s = v.components(separatedBy: "-")[0].components(separatedBy: ".")
            return (0..<3).map { $0 < s.count ? Int(s[$0]) ?? 0 : 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<3 where pa[i] != pb[i] { return pa[i] < pb[i] ? -1 : 1 }
        return 0
    }
}

public enum PairingProtocol {
    public static let cap = "pair_v1"
    public static func request(_ deviceName: String?) -> JSONObject {
        ["type": .string("pair_request"), "device_name": .string(deviceName ?? "Headset")]
    }
}
