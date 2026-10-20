// Ported from quest-app/Assets/Scripts/World/SessionState.cs @ 6017fc2.
import Foundation

public struct LinkHealth: Sendable {
    public var cardAfter = 5.0
    public var hideAfter = 1.5
    private var start = 0.0
    private var downSince = -1.0
    public private(set) var up = false
    public private(set) var everConnected = false
    public init() {}
    public mutating func newServer(_ now: Double) {
        start = now; everConnected = false; up = false; downSince = now
    }
    public mutating func update(_ connected: Bool, _ now: Double) {
        guard connected != up else { return }
        up = connected
        if connected { everConnected = true; downSince = -1 } else { downSince = now }
    }
    public func showCard(_ fatal: Bool, _ now: Double) -> Bool {
        fatal || (!everConnected && !up && now - start >= cardAfter)
    }
    public var offline: Bool { everConnected && !up }
    public func hideFigures(_ now: Double) -> Bool { !up && downSince >= 0 && now - downSince >= hideAfter }
}

public enum SetupCard {
    public static let title = "Can't reach the Minecraft server"
    public static let disclaimer = "NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT."
    private static func short(_ s: String?, _ n: Int) -> String {
        guard let s, !s.isEmpty else { return "-" }
        return s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
    public static func text(_ url: String, _ status: String, _ fatalCode: Int, _ fatalReason: String,
                            _ configPath: String, _ paused: Bool = false) -> String {
        let heading = fatalCode == 4003 ? "The server refused this headset"
            : fatalCode == 4001 ? "App and server don't match"
            : fatalCode == 1 ? "The server address isn't valid" : title
        return "\(heading)\n\nServer: \(short(url, 56))\nStatus: \(short(fatalCode != 0 ? fatalReason : status, 64))\n\n"
            + "Settings: \(short(configPath, 64))\n\n"
            + "Fix it here: menu button (left) > Info > Server\n"
            + "  (type the PC's address or pick a found server)\n"
            + "or edit tabletop.json: see docs/QUEST_SETUP.md Part D.\n"
            + (fatalCode != 0 ? "Not retrying until the address or token changes." : "Retrying...")
    }
    public static func pairText(_ code: PairCode, _ now: Double, _ host: String) -> String {
        let s = code.secondsLeft(now)
        return "Pair this headset with your server\n\n<size=110>\(code.spaced)</size>\n\n"
            + "In the server window on your PC, type:\n   tabletop pair \(code.code)\n"
            + "(in game, as an operator: /tabletop pair \(code.code))\n\n"
            + "Server: \(short(host, 48))   code valid \(s / 60):\(String(format: "%02d", s % 60))\n"
            + (code.required ? "The world loads once the server knows this headset."
               : "The world works meanwhile; pairing adds the game's textures and sounds.")
            + "\n\n<size=34>NOT AN OFFICIAL MINECRAFT PRODUCT.\nNOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT.</size>"
    }
    public static func firstRunText(_ run: FirstRun) -> String {
        let found = run.searches == 0 ? "Looking for your Minecraft server on this Wi-Fi..."
            : run.candidates == 0 ? "No server found on this Wi-Fi yet (searched \(run.searches)x, again every \(String(format: "%.0f", run.interval)) s)."
            : "Found \(run.candidates) servers: pick yours in the menu (left menu button) > Info > Server."
        return "Welcome to Tabletop Craft AR\n\n\(found)\n\n"
            + "1. On your PC, start Minecraft: Java Edition once (same version as the server).\n"
            + "2. Run the server starter there (start.bat / start.sh, see the setup guide).\n"
            + "3. This headset finds it on the same Wi-Fi and asks to pair.\n\n"
            + "Or type its address: menu button (left) > Info > Server.\n\n" + disclaimer
    }
}

public struct FirstRun: Sendable {
    public var active = false
    public var interval = 8.0
    public private(set) var searches = 0
    public private(set) var candidates = 0
    private var next = 0.0
    public init() {}
    public func shouldSearch(_ now: Double, _ searching: Bool) -> Bool { active && !searching && now >= next }
    public mutating func searched(_ found: [FoundServer]?, _ now: Double) -> String? {
        searches += 1; next = now + interval
        let real = (found ?? []).filter { !$0.portOnly }
        candidates = real.count
        return active && real.count == 1 ? real[0].url : nil
    }
    public mutating func done() { active = false }
}

public struct LoadProgress: Sendable {
    public var minSections = 24
    private var total = 0
    public init() {}
    public var active: Bool { total > 0 }
    public mutating func begin(_ pending: Int) { total = pending >= minSections ? pending : 0 }
    public mutating func text(_ pending: Int) -> String? {
        guard total > 0 else { return nil }
        if pending <= 0 { total = 0; return "Area loaded" }
        total = max(total, pending)
        return "Loading area \(100 * (total - pending) / total) %"
    }
    public mutating func cancel() { total = 0 }
}

public struct HoldButton: Sendable {
    public enum Event: Sendable { case none, pressed, fired, released }
    public var holdSeconds: Float = 0.5
    private var downAt: Float = -1
    private var fired = false
    private var ignore = false
    public init() {}
    public func progress(_ now: Float) -> Float { downAt < 0 || ignore ? 0 : min(1, (now - downAt) / holdSeconds) }
    @discardableResult public mutating func update(_ down: Bool, _ now: Float, _ blocked: Bool) -> Event {
        if !down {
            let was = downAt >= 0 && !ignore
            downAt = -1; fired = false; ignore = false
            return was ? .released : .none
        }
        if blocked { ignore = true }
        if ignore { return .none }
        if downAt < 0 { downAt = now; return .pressed }
        if !fired && now - downAt >= holdSeconds { fired = true; return .fired }
        return .none
    }
}

/// Inactive transitions (focus, system panels) do not pause a connection.
/// Only a background disconnect arms a single foreground resume.
public struct ConnectionLifecycle: Sendable {
    public private(set) var pausedForBackground = false
    public init() {}
    public mutating func pause(wantsConnection: Bool) { pausedForBackground = wantsConnection }
    public mutating func cancelPause() { pausedForBackground = false }
    public mutating func resume(wantsConnection: Bool) -> Bool {
        let reconnect = pausedForBackground && wantsConnection
        pausedForBackground = false
        return reconnect
    }
}
