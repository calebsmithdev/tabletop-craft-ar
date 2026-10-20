// Port of quest-app/Assets/Scripts/Net/LinkClient.cs at c015e32.
import Foundation

/// Actor-owned bounded FIFO. A full snapshot supersedes queued snapshots and block updates, not control messages.
public struct InboundQueue: Sendable {
    public static let max = 4096
    private var messages: [JSONObject] = []
    public private(set) var dropped = 0
    public var count: Int { messages.count }
    public var full: Bool { count >= Self.max }
    public init() {}
    public static func isFullSnapshotStart(_ m: JSONObject) -> Bool {
        m.s("type") == "chunk_snapshot" && m.o("base") == nil && m.i("part") == 0
    }
    @discardableResult public mutating func enqueue(_ m: JSONObject) -> Bool {
        if Self.isFullSnapshotStart(m) {
            let before = count
            messages.removeAll { $0.s("type") == "chunk_snapshot" || $0.s("type") == "block_update" }
            dropped += before - count
        }
        guard !full else { return false }
        messages.append(m)
        return true
    }
    public mutating func drain() -> [JSONObject] { let result = messages; messages.removeAll(keepingCapacity: true); return result }
    public mutating func clear() { messages.removeAll(keepingCapacity: true) }
}

public enum LinkState: String, Sendable {
    case idle, connecting, connected, pairing, welcomed, reconnecting, stopped, fatal
}

public struct LinkConfiguration: Sendable {
    public var pingSeconds: Double = 2
    public var deadSeconds: Double = 6
    public var connectTimeoutSeconds: Double = 5
    public var backoffInitialSeconds: Double = 0.5
    public var backoffMaxSeconds: Double = 8
    public var shutdownSeconds: Double = 0.4
    public init() {}
}

/// Background link owner. All public state is actor-isolated; no UI or MainActor dependency.
public actor LinkClient {
    public nonisolated let url: String
    public private(set) var state: LinkState = .idle
    public private(set) var status = "idle"
    public private(set) var rttMs: Double = -1
    public private(set) var fatalCode = 0
    public private(set) var fatalReason = ""
    public private(set) var welcomes = 0
    public private(set) var deadAborts = 0
    public private(set) var posesDropped = 0
    public private(set) var inbound = InboundQueue()
    public var connected: Bool { welcomed && transport != nil }
    public var pairing: Bool { state == .pairing }
    public var deviceToken: String?
    public var deviceName: String?
    public private(set) var deviceTokenRejected = false

    private let address: URL?
    private let token: String
    private let configuration: LinkConfiguration
    private let transportFactory: @Sendable () -> any LinkTransport
    private let binary: (@Sendable (Data) async -> Void)?
    private var transport: (any LinkTransport)?
    private var loop: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var envelope = Envelope()
    private var welcomed = false
    private var stopping = false
    private var sentDeviceToken: String?
    private var rejectedDeviceToken: String?
    private var lastInbound = ContinuousClock.now
    private var pingId = 0
    private var connectTimedOut = false
    private var dead = false
    private struct Pending: Sendable { let body: JSONObject; let seq: UInt32? }
    private var outbound: [Pending] = []
    private var pose: Pending?

    public init(url: String, token: String? = nil, deviceToken: String? = nil,
                deviceName: String? = "Apple Vision Pro", configuration: LinkConfiguration = .init(),
                transportFactory: @escaping @Sendable () -> any LinkTransport = { NWLinkTransport() },
                binary: (@Sendable (Data) async -> Void)? = nil) {
        self.url = url; self.token = token ?? ""; self.deviceToken = deviceToken; self.deviceName = deviceName
        self.configuration = configuration; self.transportFactory = transportFactory; self.binary = binary
        if let u = URL(string: url), ["ws", "wss"].contains(u.scheme ?? ""), u.host != nil {
            address = u
        } else {
            address = nil; fatalCode = 1; fatalReason = "not a ws:// address: " + url
            status = fatalReason; state = .fatal
        }
    }

    public func start() {
        guard address != nil, loop == nil, fatalCode == 0 else { return }
        stopping = false
        loop = Task { await runLoop() }
    }

    public func drain() -> [JSONObject] { inbound.drain() }
    /// Consume the credential rejected by 4003 once. Consumers must only forget a
    /// persisted entry if it still contains this token: pairing may already have
    /// replaced it while the owner was processing earlier inbound messages.
    public func takeRejectedDeviceToken() -> String? {
        defer { rejectedDeviceToken = nil; deviceTokenRejected = false }
        return rejectedDeviceToken
    }

    public func setDeviceToken(_ value: String?) { deviceToken = value }
    public func setDeviceName(_ value: String?) { deviceName = value }

    /// Drops messages while not welcomed, matching the Quest client.
    public func send(_ body: JSONObject) { guard connected, !stopping else { return }; post(body) }
    /// Reserve the envelope seq now for a future reply's ref_seq; -1 means the message was not queued.
    @discardableResult public func sendTracked(_ body: JSONObject) -> Int64 {
        guard connected, !stopping, outbound.count < InboundQueue.max else { return -1 }
        let seq = envelope.reserve()
        post(body, seq: seq)
        return Int64(seq)
    }
    public func sendPairing(_ body: JSONObject) {
        guard transport != nil, !stopping, welcomed || (pairing && Self.isPairingTraffic(body)) else { return }
        post(body)
    }
    public func reconnect() async { await transport?.cancel() }

    public func stop(reason: String = "app closed") async {
        guard !stopping else { return }
        stopping = true
        let current = transport
        // A wedged send must never prevent shutdown. Cancellation unblocks every transport operation.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(max(0.001, configuration.shutdownSeconds)))
            if !Task.isCancelled { await current?.cancel() }
        }
        // Let the current write finish before bye. Cancelling a Network.framework write
        // cancels its connection too; the watchdog handles a write that cannot finish.
        if let sender { await sender.value }
        if let current, welcomed || pairing {
            try? await emit(Protocol.bye(reason), via: current)
            // The peer answers bye with close. Keep receiving until that arrives; the same
            // watchdog aborts a silent peer without extending the total shutdown budget.
            if let loop { await loop.value }
        }
        loop?.cancel()
        await current?.cancel()
        if let loop { await loop.value }
        watchdog.cancel()
        self.loop = nil; self.sender = nil; transport = nil
        outbound.removeAll(); pose = nil; welcomed = false; rttMs = -1
        state = .stopped; status = "stopped (\(reason))"
    }

    private static func isPairingTraffic(_ body: JSONObject) -> Bool {
        ["ping", "pong", "pair_request", "bye"].contains(body.s("type") ?? "")
    }
    private func post(_ body: JSONObject, seq: UInt32? = nil) {
        let pending = Pending(body: body, seq: seq)
        if body.s("type") == "pose" {
            if pose != nil { posesDropped += 1 }; pose = pending
        } else {
            guard outbound.count < InboundQueue.max else { return }
            outbound.append(pending)
        }
        if sender == nil {
            let id = generation
            sender = Task { await senderLoop(id) }
        }
    }
    private func senderLoop(_ id: UInt64) async {
        while id == generation, !stopping, !Task.isCancelled, let current = transport {
            let item: Pending
            if !outbound.isEmpty { item = outbound.removeFirst() }
            else if let latest = pose { item = latest; pose = nil }
            else { break }
            guard welcomed || (pairing && Self.isPairingTraffic(item.body)) else { continue }
            do { try await emit(item.body, seq: item.seq, via: current) }
            catch { await current.cancel(); break }
        }
        if id == generation { sender = nil }
    }
    private func emit(_ body: JSONObject, seq: UInt32? = nil, via transport: any LinkTransport) async throws {
        let message = envelope.wrap(body, seq: seq)
        try await transport.send(.text(Json.stringify(message)))
    }

    private func runLoop() async {
        guard let address else { return }
        var backoff = configuration.backoffInitialSeconds
        while !stopping, !Task.isCancelled, fatalCode == 0 {
            generation &+= 1
            let id = generation, current = transportFactory()
            transport = current; welcomed = false; connectTimedOut = false; dead = false
            state = .connecting; status = "connecting"
            let deadline = Task {
                try? await Task.sleep(for: .seconds(max(0.001, configuration.connectTimeoutSeconds)))
                if !Task.isCancelled { await connectExpired(id, current) }
            }
            do {
                try await current.connect(url: address)
                deadline.cancel()
                guard !stopping, !Task.isCancelled else { throw CancellationError() }
                envelope = Envelope(); lastInbound = .now; sentDeviceToken = deviceToken
                try await emit(Protocol.hello(token, deviceToken: sentDeviceToken, deviceName: deviceName), via: current)
                state = .connected; status = "connected"; backoff = configuration.backoffInitialSeconds
                let keep = Task { await keepAlive(id, current) }
                do { try await receiveLoop(id, current) }
                catch { if !stopping { status = dead ? "no answer: reconnecting" : "error: \(error)" } }
                keep.cancel()
                await keep.value
            } catch {
                if !stopping { status = connectTimedOut ? "connect timeout" : "error: \(error)" }
            }
            deadline.cancel()
            sender?.cancel()
            await current.cancel()
            if let sender { await sender.value }
            sender = nil; transport = nil; outbound.removeAll(); pose = nil; welcomed = false; rttMs = -1
            if stopping || Task.isCancelled || fatalCode != 0 { break }
            state = .reconnecting
            do { try await Task.sleep(for: .seconds(max(0.001, backoff))) } catch { break }
            backoff = min(backoff * 2, configuration.backoffMaxSeconds)
        }
        if fatalCode != 0 { state = .fatal; status = fatalReason }
    }
    private func connectExpired(_ id: UInt64, _ current: any LinkTransport) async {
        guard generation == id, state == .connecting else { return }
        connectTimedOut = true
        await current.cancel()
    }
    private func keepAlive(_ id: UInt64, _ current: any LinkTransport) async {
        var nextPing = ContinuousClock.now + .seconds(configuration.pingSeconds)
        while !Task.isCancelled, !stopping, id == generation {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            if ContinuousClock.now - lastInbound > .seconds(configuration.deadSeconds) {
                dead = true; deadAborts += 1; await current.cancel(); return
            }
            if (welcomed || pairing), ContinuousClock.now >= nextPing {
                nextPing = .now + .seconds(configuration.pingSeconds)
                post(Protocol.ping(pingId)); pingId &+= 1
            }
        }
    }
    private func receiveLoop(_ id: UInt64, _ current: any LinkTransport) async throws {
        var partial = Data()
        // stop owns graceful shutdown: keep receiving until it cancels the loop/transport,
        // so an in-flight pong cannot make runLoop tear down the socket before bye is sent.
        while !Task.isCancelled, generation == id {
            while inbound.full, !Task.isCancelled, !stopping {
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            let frame = try await current.receive()
            lastInbound = .now
            let text: String
            switch frame {
            case .close(let code, let reason):
                status = "closed \(code) \(reason)"
                if code == 4001 { fatalCode = code; fatalReason = "the server speaks another protocol version: update the app or the plugin" }
                else if code == 4003, let sentDeviceToken, !sentDeviceToken.isEmpty {
                    deviceTokenRejected = true
                    rejectedDeviceToken = sentDeviceToken
                    if deviceToken == sentDeviceToken { deviceToken = nil }
                    status = "this headset was unpaired: pairing again"
                } else if code == 4003 { fatalCode = code; fatalReason = "the server refused this headset: check its token or pairing" }
                return
            case .binary(let bytes): await binary?(bytes); continue
            case .text(let string): text = string
            case .fragment(let bytes, let isText, let isComplete):
                guard bytes.count <= NWLinkTransport.maximumMessageSize - partial.count else { throw LinkTransportError.messageTooLarge }
                partial.append(bytes)
                if !isComplete { continue }
                let message = partial; partial = Data()
                if !isText { await binary?(message); continue }
                guard let string = String(data: message, encoding: .utf8) else { throw LinkTransportError.invalidUTF8 }
                text = string
            }
            guard let message = try? Json.parse(text).objectValue else { continue }
            switch message.s("type") {
            case "pong": rttMs = max(0, Date().timeIntervalSince1970 * 1000 - message.d("echo_t")); continue
            case "ping":
                // No pre-welcome traffic except while the server explicitly waits for pairing.
                if welcomed || pairing { post(Protocol.pong(message)) }
                continue
            case "pair_code":
                if !welcomed { state = .pairing }
            case "welcome":
                welcomed = true; state = .welcomed; welcomes += 1
            default: break
            }
            inbound.enqueue(message)
        }
    }
}
