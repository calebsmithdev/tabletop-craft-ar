// Transport seam for quest-app/Assets/Scripts/Net/LinkClient.cs at c015e32.
import Foundation
import Network

public enum LinkFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
    case close(code: Int, reason: String)
    /// A receive can complete before the WebSocket message does. Every nonempty fragment is activity.
    case fragment(Data, isText: Bool, isComplete: Bool)
}

public enum LinkTransportError: Error, Sendable, Equatable {
    case invalidURL, notConnected, timeout, closed, invalidUTF8, messageTooLarge
}

/// One transport per connection attempt. cancel() must unblock connect, receive and send.
public protocol LinkTransport: Sendable {
    func connect(url: URL) async throws
    func send(_ frame: LinkFrame) async throws
    func receive() async throws -> LinkFrame
    func cancel() async
}

/// Network.framework WebSocket with partial receives, a 4 MiB message limit and application close codes.
public actor NWLinkTransport: LinkTransport {
    public static let maximumMessageSize = 4 << 20
    private var connection: NWConnection?
    private var opening: CheckedContinuation<Void, any Error>?
    private let queue = DispatchQueue(label: "tabletop-link")
    private var incomingText = true
    private var incomingSize = 0
    /// An error that arrived together with data: the data is returned first, the error on the next receive.
    private var pendingError: (any Error)?

    public init() {}

    public func connect(url: URL) async throws {
        guard connection == nil, let scheme = url.scheme, ["ws", "wss"].contains(scheme), url.host != nil else {
            throw LinkTransportError.invalidURL
        }
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = Self.maximumMessageSize
        let parameters = NWParameters(tls: scheme == "wss" ? NWProtocolTLS.Options() : nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                opening = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { await self?.changed(state) }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready: opening?.resume(); opening = nil
        case .failed(let error): opening?.resume(throwing: error); opening = nil
        case .cancelled: opening?.resume(throwing: CancellationError()); opening = nil
        default: break
        }
    }

    public func send(_ frame: LinkFrame) async throws {
        guard let connection else { throw LinkTransportError.notConnected }
        let data: Data
        let metadata: NWProtocolWebSocket.Metadata
        switch frame {
        case .text(let string): data = Data(string.utf8); metadata = .init(opcode: .text)
        case .binary(let bytes): data = bytes; metadata = .init(opcode: .binary)
        case .close(let code, let reason):
            guard let raw = UInt16(exactly: code) else { throw LinkTransportError.closed }
            metadata = .init(opcode: .close)
            metadata.closeCode = try .init(rawValue: raw)
            data = Data(reason.utf8)
        case .fragment: throw LinkTransportError.closed
        }
        guard data.count <= Self.maximumMessageSize else { throw LinkTransportError.messageTooLarge }
        let context = NWConnection.ContentContext(identifier: "tabletop", metadata: [metadata])
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }

    public func receive() async throws -> LinkFrame {
        guard let connection else { throw LinkTransportError.notConnected }
        while true {
            if let pendingError { self.pendingError = nil; throw pendingError }
            // receiveMessage waits for the full frame. receive lets the link count in-flight bytes.
            let packet: (Data, NWProtocolWebSocket.Opcode?, Int?, Bool, (any Error)?) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, context, complete, error in
                        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                        // A close frame may arrive with an EOF/error: preserve its code before considering the error.
                        if let metadata, metadata.opcode == .close {
                            let code: Int
                            switch metadata.closeCode {
                            case .protocolCode(let c): code = Int(c.rawValue)
                            case .applicationCode(let c), .privateCode(let c): code = Int(c)
                            @unknown default: code = 1006
                            }
                            continuation.resume(returning: (data ?? Data(), .close, code, complete, nil))
                        } else if let error, (data ?? Data()).isEmpty { continuation.resume(throwing: error) }
                        // A peer that sends and closes at once can deliver its last message with the error.
                        else { continuation.resume(returning: (data ?? Data(), metadata?.opcode, nil, complete, error)) }
                    }
                }
            } onCancel: { connection.cancel() }
            let (data, opcode, code, complete, error) = packet
            if let error { pendingError = error }
            if opcode == .close { return .close(code: code ?? 1006, reason: String(decoding: data, as: UTF8.self)) }
            if opcode == .ping || opcode == .pong { continue }
            if incomingSize == 0 {
                if opcode == .text { incomingText = true }
                else if opcode == .binary { incomingText = false }
                else if data.isEmpty { throw LinkTransportError.closed }
            }
            guard data.count <= Self.maximumMessageSize - incomingSize else {
                connection.cancel(); throw LinkTransportError.messageTooLarge
            }
            incomingSize += data.count
            if complete { incomingSize = 0 }
            return .fragment(data, isText: incomingText, isComplete: complete)
        }
    }

    public func cancel() {
        opening?.resume(throwing: CancellationError()); opening = nil
        connection?.cancel()
        connection = nil
    }
}
