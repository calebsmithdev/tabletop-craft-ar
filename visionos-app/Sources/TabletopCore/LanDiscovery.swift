// Ported from quest-app/Assets/Scripts/Net/LanDiscovery.cs @ c015e32.
import Foundation
import Darwin
import Dispatch
import Synchronization

public enum ServerAddress {
    public static let defaultPort = 8765
    public static let defaultPath = "/tabletop"
    public static func normalize(_ text: String?) -> String? {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        let scheme = t.contains("://")
        guard var c = URLComponents(string: scheme ? t : "ws://" + t),
              let s = c.scheme?.lowercased(), s == "ws" || s == "wss",
              let host = c.host?.lowercased(), !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:[]".contains($0) }) else { return nil }
        let port = c.port ?? (scheme ? (s == "wss" ? 443 : 80) : defaultPort)
        guard port > 0, port <= 65535 else { return nil }
        c.scheme = s; c.host = host; c.port = port
        if c.path.isEmpty || c.path == "/" { c.path = defaultPath }
        // The reference builds a URL from scheme, host, port and path only.
        c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
        return c.string
    }
    public static func hostOf(_ url: String?) -> String {
        guard let url else { return "" }
        return URLComponents(string: url)?.host ?? url
    }
}

public struct FoundServer: Sendable, Equatable {
    public var name = "", url = "", host = "", mc = "", version = ""
    public var players = 0
    public var tokenNeeded = false, portOnly = false
    public var id = ""
    public var pair = false
    public init() {}
    public var label: String {
        var s = portOnly ? "\(host) (port open)" : "\(name.isEmpty ? "Server" : name) (\(host))"
        if tokenNeeded && !pair { s += " token" }
        return s.count > 40 ? String(s.prefix(39)) + "…" : s
    }
}

public struct DiscoveryDatagram: Sendable {
    public let data: Data
    public let senderHost: String
    public init(data: Data, senderHost: String) { self.data = data; self.senderHost = senderHost }
}

public protocol LanDiscoveryTransport: Sendable {
    func localIPv4() throws -> [String]
    func probeUdp(_ probe: Data, targets: [String], port: Int, timeoutMs: Int, maxReplyBytes: Int) async throws -> [DiscoveryDatagram]
    func checkTcp(_ host: String, port: Int, timeoutMs: Int) async throws -> Bool
}

public enum LanDiscovery {
    public static let probeType = "tabletop_discover", replyType = "tabletop_server"
    public static let maxReplyBytes = 2048
    public static let udpTimeoutMs = 1200, tcpTimeoutMs = 400, tcpParallel = 48
    public static func probe() throws -> Data {
        Data(try Json.stringify(.object(["type": .string(probeType), "v": .number(1)])).utf8)
    }
    public static func parseReply(_ json: String, _ senderHost: String) -> FoundServer? {
        guard case .object(let m) = try? Json.parse(json), m.s("type") == replyType, m.i("v") == 1 else { return nil }
        let port = m.i("port"), path = m.s("path") ?? ServerAddress.defaultPath
        guard port > 0, port <= 65535, path.hasPrefix("/"),
              let url = ServerAddress.normalize("ws://\(senderHost):\(port)\(path)") else { return nil }
        var f = FoundServer()
        f.name = String((m.s("name") ?? "").prefix(48)); f.url = url; f.host = senderHost
        f.mc = m.s("mc") ?? ""; f.version = m.s("version") ?? ""
        f.players = max(0, m.i("players")); f.tokenNeeded = m.b("token")
        f.id = m.s("id") ?? ""; f.pair = m.b("pair")
        return f
    }
    private static func octets(_ host: String?) -> [UInt8]? {
        guard let host else { return nil }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return UInt8(part)
        }
        return bytes.count == 4 ? bytes : nil
    }
    public static func isPrivate(_ host: String?) -> Bool {
        guard let b = octets(host) else { return false }
        return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32)
            || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }
    public static func isUnicast(_ host: String) -> Bool {
        guard let b = octets(host) else { return false }
        return b[0] > 0 && b[0] < 224 && b[3] > 0 && b[3] < 255
    }
    public static func subnet24(_ local: String?) -> [String] {
        guard let b = octets(local) else { return [] }
        return (1..<255).map { "\(b[0]).\(b[1]).\(b[2]).\($0)" }.filter(isUnicast)
    }
    // D5: unicast sweep replaces the Quest broadcast targets.
    public static func targets(_ local: String?) -> [String] { subnet24(local) }
    public static func targets(_ locals: [String]) -> [String] { Array(Set(locals.flatMap { targets($0) })).sorted() }
    public static func localIPv4() throws -> [String] { try BSDDiscoveryTransport().localIPv4() }
    public static func probeUdp(_ targets: [String], _ port: Int, _ timeoutMs: Int,
                                transport: any LanDiscoveryTransport = BSDDiscoveryTransport()) async throws -> [FoundServer] {
        let replies = try await transport.probeUdp(probe(), targets: Array(Set(targets.filter(isUnicast))).sorted(),
                                                   port: port, timeoutMs: timeoutMs, maxReplyBytes: maxReplyBytes)
        var urls: Set<String> = []
        return replies.compactMap { d in
            guard d.data.count <= maxReplyBytes, let json = String(data: d.data, encoding: .utf8),
                  let f = parseReply(json, d.senderHost), urls.insert(f.url).inserted else { return nil }
            return f
        }
    }
    public static func scanTcp(_ hosts: [String], _ port: Int, _ timeoutMs: Int, parallel: Int = tcpParallel,
                               transport: any LanDiscoveryTransport = BSDDiscoveryTransport()) async -> [FoundServer] {
        let hosts = Array(Set(hosts.filter(isUnicast))).sorted()
        return await withTaskGroup(of: FoundServer?.self) { group in
            var next = 0
            func check(_ host: String) async -> FoundServer? {
                guard !Task.isCancelled, (try? await transport.checkTcp(host, port: port, timeoutMs: timeoutMs)) == true else { return nil }
                var f = FoundServer(); f.host = host; f.url = "ws://\(host):\(port)\(ServerAddress.defaultPath)"; f.portOnly = true
                return f
            }
            for _ in 0..<min(tcpParallel, max(1, parallel), hosts.count) {
                let host = hosts[next]; next += 1
                group.addTask { await check(host) }
            }
            var found: [FoundServer] = []
            for await result in group {
                if let result { found.append(result) }
                if next < hosts.count && !Task.isCancelled {
                    let host = hosts[next]; next += 1
                    group.addTask { await check(host) }
                }
            }
            return found.sorted { $0.host < $1.host }
        }
    }
    public static func find(port: Int = ServerAddress.defaultPort, udpMs: Int = udpTimeoutMs, tcpMs: Int = tcpTimeoutMs,
                            transport: any LanDiscoveryTransport = BSDDiscoveryTransport()) async throws -> [FoundServer] {
        let hosts = targets(try transport.localIPv4())
        let found = try await probeUdp(hosts, port, udpMs, transport: transport)
        if !found.isEmpty || hosts.isEmpty { return found }
        return await scanTcp(hosts, port, tcpMs, transport: transport)
    }
}

public struct DiscoverySocketError: Error, Sendable {
    public let code: Int32
    public init(_ code: Int32) { self.code = code }
}

// The synchronous seam lets tests exercise the production queue bridge without sockets.
protocol BlockingDiscoverySockets: Sendable {
    func probeUdp(_ probe: Data, targets: [String], port: Int, timeoutMs: Int,
                  maxReplyBytes: Int, cancellation: DiscoveryCancellation) throws -> [DiscoveryDatagram]
    func checkTcp(_ host: String, port: Int, timeoutMs: Int, cancellation: DiscoveryCancellation) throws -> Bool
}

final class DiscoveryCancellation: Sendable {
    private let cancelled = Mutex(false)
    func cancel() { cancelled.withLock { $0 = true } }
    func check() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
}

public struct BSDDiscoveryTransport: LanDiscoveryTransport, Sendable {
    // Unlike @concurrent or Task.detached, this queue does not occupy Swift's
    // cooperative executor while poll waits. scanTcp bounds each sweep to 48 jobs.
    private static let queue = DispatchQueue(label: "TabletopCraft.discovery", qos: .utility, attributes: .concurrent)
    private let sockets: any BlockingDiscoverySockets

    public init() { sockets = BSDDiscoverySockets() }
    init(sockets: any BlockingDiscoverySockets) { self.sockets = sockets }

    private func blocking<Value: Sendable>(
        _ operation: @escaping @Sendable (DiscoveryCancellation) throws -> Value
    ) async throws -> Value {
        let cancellation = DiscoveryCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    // Keep the continuation (and scan slot) until the worker exits;
                    // cancellation never closes a descriptor on another thread.
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let value = try operation(cancellation)
                        try cancellation.check()
                        return value
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func probeUdp(_ probe: Data, targets: [String], port: Int, timeoutMs: Int,
                         maxReplyBytes: Int) async throws -> [DiscoveryDatagram] {
        try await blocking { cancellation in
            try sockets.probeUdp(probe, targets: targets, port: port, timeoutMs: timeoutMs,
                                 maxReplyBytes: maxReplyBytes, cancellation: cancellation)
        }
    }

    public func checkTcp(_ host: String, port: Int, timeoutMs: Int) async throws -> Bool {
        try await blocking { cancellation in
            try sockets.checkTcp(host, port: port, timeoutMs: timeoutMs, cancellation: cancellation)
        }
    }

    public func localIPv4() throws -> [String] { try BSDDiscoverySockets().localIPv4() }
}

// One bound UDP socket for the complete sweep. No SO_BROADCAST or multicast options.
private struct BSDDiscoverySockets: BlockingDiscoverySockets {
    public func localIPv4() throws -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw DiscoverySocketError(errno) }
        defer { freeifaddrs(first) }
        var hosts: Set<String> = []
        var cursor = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            let v4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            if let host = Self.host(v4), LanDiscovery.isUnicast(host) { hosts.insert(host) }
        }
        return hosts.sorted()
    }
    private static func address(_ host: String, _ port: Int) -> sockaddr_in? {
        guard LanDiscovery.isUnicast(host), port > 0, port <= 65535 else { return nil }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(port).bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &a.sin_addr) }) == 1 else { return nil }
        return a
    }
    private static func host(_ address: sockaddr_in) -> String? {
        var a = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &a, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    private static func remaining(_ deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= deadline ? 0 : Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
    }
    func probeUdp(_ probe: Data, targets: [String], port: Int, timeoutMs: Int,
                  maxReplyBytes: Int, cancellation: DiscoveryCancellation) throws -> [DiscoveryDatagram] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw DiscoverySocketError(errno) }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw DiscoverySocketError(errno) }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &local) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        guard bound == 0 else { throw DiscoverySocketError(errno) }
        var sent = 0
        for target in targets {
            try cancellation.check()
            guard var a = Self.address(target, port) else { continue }
            let n = probe.withUnsafeBytes { bytes in withUnsafePointer(to: &a) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } }
            if n >= 0 { sent += 1 }
        }
        guard sent > 0 else { return [] }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000
        var replies: [DiscoveryDatagram] = []
        var buffer = [UInt8](repeating: 0, count: max(1, maxReplyBytes + 1))
        while Self.remaining(deadline) > 0 {
            try cancellation.check()
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, min(25, Self.remaining(deadline)))
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { continue }
            if ready < 0 { break }
            var from = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
            } }
            guard n >= 0 else { break }
            if n <= maxReplyBytes, let host = Self.host(from) { replies.append(DiscoveryDatagram(data: Data(buffer.prefix(n)), senderHost: host)) }
        }
        return replies
    }
    func checkTcp(_ host: String, port: Int, timeoutMs: Int, cancellation: DiscoveryCancellation) throws -> Bool {
        try cancellation.check()
        guard var a = Self.address(host, port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DiscoverySocketError(errno) }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw DiscoverySocketError(errno) }
        let result = withUnsafePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000
        while Self.remaining(deadline) > 0 {
            try cancellation.check()
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&event, 1, min(25, Self.remaining(deadline)))
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { continue }
            guard ready > 0 else { return false }
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
        }
        return false
    }
}
