// Engine-free port of World/AssetSync.cs. All disk/hash work is actor-isolated,
// never MainActor-isolated. One owner per directory; call drainRequests periodically.
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public actor AssetSync {
    public enum State: String, Sendable { case checking, upToDate, waiting, downloading, verifying, done, failed }
    public struct Item: Sendable {
        public let offer: AssetFile
        public fileprivate(set) var state: State = .checking
        public fileprivate(set) var received: Int64 = 0
        public fileprivate(set) var requested: Int64 = 0
        public fileprivate(set) var inFlight = 0
        public fileprivate(set) var note = ""
    }
    public struct Completion: Sendable, Equatable {
        public let name: String
        public let url: URL
    }
    public struct Snapshot: Sendable {
        public let items: [Item]
        public let offered: Bool
        public let serverState: String
        public let serverNote: String
        public let bytesReceived: Int64
        public let downloaded: Int
        public var busy: Bool { items.contains { [.checking, .waiting, .downloading, .verifying].contains($0.state) } }
        public var status: String {
            if !offered { return items.isEmpty ? "not offered by this server" : "waiting for the server" }
            if items.isEmpty {
                return (serverState == "building" ? "the server is preparing the game files" : "the server offers nothing")
                    + (serverNote.isEmpty ? "" : ": " + serverNote)
            }
            return items.map { "\($0.offer.name) \($0.state == .upToDate ? "up to date" : $0.state.rawValue)\($0.note.isEmpty ? "" : " (\($0.note))")" }.joined(separator: ", ")
        }
    }
    public static let hashCache = "assets_hashes.json"
    public let directory: URL
    public let allowedNames: Set<String>
    private let hash: @Sendable (URL) throws -> String
    private let stallSeconds: Double
    private var items: [Item] = []
    private var offered = false, serverState = "", serverNote = ""
    private var bytesReceived: Int64 = 0, downloaded = 0
    private var chunkSize = 262144
    private var current: Int?
    private var output: FileHandle?
    private var outstanding: [Int64: Int] = [:]
    private var lastChunk = 0.0
    private var completed: [Completion] = []
    private var forcedDownloads: Set<String> = []

    /// `hash` is injectable for synthetic tests. Production uses streaming SHA-256.
    public init(directory: URL, allowedNames: Set<String> = AssetProtocol.names,
                stallSeconds: Double = 15,
                hash: @escaping @Sendable (URL) throws -> String = AssetSync.sha256File) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.allowedNames = allowedNames.intersection(AssetProtocol.names)
        self.stallSeconds = max(0, stallSeconds); self.hash = hash
    }
    public func snapshot() -> Snapshot {
        Snapshot(items: items, offered: offered, serverState: serverState, serverNote: serverNote,
                 bytesReceived: bytesReceived, downloaded: downloaded)
    }
    /// Explicit retry for a quarantined installed file. Merely reconnecting does
    /// not retry a pack which already failed CPU/GPU validation.
    public func forceDownload(_ name: String) {
        if allowedNames.contains(name) { forcedDownloads.insert(name) }
    }
    /// Accepts the wire `assets` object. Unknown file names and duplicates are ignored.
    public func acceptOffer(_ message: JSONObject) {
        let offer = AssetProtocol.parseOffer(message)
        closeOutput(); current = nil; outstanding.removeAll()
        offered = true; serverState = offer.state; serverNote = offer.note; chunkSize = offer.chunk
        // Import replaces the same destination. Recheck its stamp even when the
        // server repeats an unchanged offer; the persisted hash cache keeps this cheap.
        items = offer.files.filter { allowedNames.contains($0.name) }.map { Item(offer: $0) }
        var cache = loadCache()
        for i in items.indices where items[i].state == .checking {
            let file = items[i].offer
            if forcedDownloads.remove(file.name) != nil { items[i].state = .waiting; continue }
            do {
                try ensureDirectory()
                let url = try safePath(file.name)
                let stamp = try fileStamp(url)
                var sha: String?
                if stamp.size == file.size {
                    let entry = cache.o(file.name)
                    if entry?.s("stamp") == stamp.value { sha = entry?.s("sha256") }
                    if sha == nil {
                        sha = try hash(url)
                        cache[file.name] = .object(["stamp": .string(stamp.value), "sha256": .string(sha ?? "")])
                    }
                }
                items[i].state = sha == file.sha256 ? .upToDate : .waiting
            } catch {
                items[i].state = .waiting
                items[i].note = "local check: \(error.localizedDescription)"
            }
        }
        saveCache(cache)
    }
    /// Returns newly requested ranges only. No requests are emitted after linkLost until a fresh offer.
    public func drainRequests(now: Double = ProcessInfo.processInfo.systemUptime) -> [JSONObject] {
        guard offered else { return [] }
        if current == nil, let next = items.firstIndex(where: { $0.state == .waiting }) { start(next, now: now) }
        guard let i = current, items[i].state == .downloading else { return [] }
        if !outstanding.isEmpty && now - lastChunk > stallSeconds {
            outstanding.removeAll(); items[i].requested = items[i].received
            items[i].note = "stalled, asking again"
        }
        var requests: [JSONObject] = []
        while outstanding.count < 4 && items[i].requested < items[i].offer.size {
            let offset = items[i].requested
            let length = Int(min(Int64(chunkSize), items[i].offer.size - offset))
            if outstanding.isEmpty { lastChunk = now }
            outstanding[offset] = length
            requests.append(AssetProtocol.get(name: items[i].offer.name, offset: offset, length: length))
            items[i].requested += Int64(length)
        }
        items[i].inFlight = outstanding.count
        return requests
    }
    public func receiveBinary(_ data: Data, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard let frame = AssetProtocol.parseChunk(data), let i = current, items[i].state == .downloading,
              frame.name == items[i].offer.name, frame.offset == items[i].received,
              outstanding[frame.offset] == frame.data.count, let output else { return }
        do {
            try output.seek(toOffset: UInt64(frame.offset)); try output.write(contentsOf: frame.data)
            outstanding.removeValue(forKey: frame.offset)
            items[i].inFlight = outstanding.count
            items[i].received += Int64(frame.data.count); bytesReceived += Int64(frame.data.count); lastChunk = now
            if items[i].received == items[i].offer.size { verify(i) }
        } catch { fail(i, "write failed: \(error.localizedDescription)") }
    }
    public func drainCompletions() -> [Completion] {
        let result = completed; completed.removeAll(); return result
    }
    @discardableResult public func receiveError(_ message: JSONObject) -> Bool {
        guard message.s("op") == "asset_get" else { return false }
        let code = message.s("code") ?? "error"
        for i in items.indices where items[i].offer.name == message.s("name") || code == "asset_denied" {
            if code == "rate_limited", current == i {
                outstanding.removeAll(); items[i].requested = items[i].received; items[i].inFlight = 0
                items[i].note = "the server asked to slow down"
            } else if [.waiting, .downloading].contains(items[i].state) {
                fail(i, code + ": " + (message.s("message") ?? ""))
            }
        }
        return true
    }
    public func linkLost() {
        offered = false
        if let i = current { items[i].state = .waiting; items[i].inFlight = 0 }
        closeOutput(); current = nil; outstanding.removeAll()
    }
    private func start(_ i: Int, now: Double) {
        do {
            try ensureDirectory()
            let file = items[i].offer
            let part = try safePath(file.name + ".part"), side = try safePath(file.name + ".part.sha")
            var have: Int64 = 0
            if let sideText = try? String(contentsOf: side, encoding: .utf8),
               sideText.trimmingCharacters(in: .whitespacesAndNewlines) == file.sha256,
               let stamp = try? fileStamp(part) {
                have = min(stamp.size, file.size) / Int64(chunkSize) * Int64(chunkSize)
            } else {
                try? FileManager.default.removeItem(at: part)
                try file.sha256.write(to: side, atomically: true, encoding: .utf8)
            }
            if !FileManager.default.fileExists(atPath: part.path) {
                guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            output = try FileHandle(forWritingTo: part)
            try output?.truncate(atOffset: UInt64(have))
            current = i; outstanding.removeAll()
            items[i].state = .downloading; items[i].received = have; items[i].requested = have; items[i].inFlight = 0
            items[i].note = have > 0 ? "resuming at \(have) bytes" : ""; lastChunk = now
            if have == file.size { verify(i) }
        } catch { closeOutput(); fail(i, "can't start download: \(error.localizedDescription)") }
    }
    private func verify(_ i: Int) {
        closeOutput(); outstanding.removeAll(); items[i].inFlight = 0; items[i].state = .verifying
        do {
            let file = items[i].offer
            let part = try safePath(file.name + ".part"), destination = try safePath(file.name)
            guard try hash(part) == file.sha256 else {
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: safePath(file.name + ".part.sha"))
                fail(i, "checksum mismatch: reconnect to try again"); return
            }
            // POSIX rename atomically replaces the old destination only after validation.
            guard rename(part.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try? FileManager.default.removeItem(at: safePath(file.name + ".part.sha"))
            items[i].state = .done; items[i].note = ""; current = nil; downloaded += 1
            completed.append(Completion(name: file.name, url: destination))
            if let stamp = try? fileStamp(destination) {
                var cache = loadCache()
                cache[file.name] = .object(["stamp": .string(stamp.value), "sha256": .string(file.sha256)])
                saveCache(cache)
            }
        } catch { fail(i, "verification/install failed: \(error.localizedDescription)") }
    }
    private func fail(_ i: Int, _ note: String) {
        items[i].state = .failed; items[i].note = note; items[i].inFlight = 0
        if current == i { closeOutput(); current = nil; outstanding.removeAll() }
    }
    private func closeOutput() { try? output?.close(); output = nil }
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory else { throw CocoaError(.fileWriteInvalidFileName) }
    }
    /// Names only originate from the fixed allowlist or fixed internal suffixes. Reject symlinks too.
    private func safePath(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return url
    }
    private func fileStamp(_ url: URL) throws -> (size: Int64, value: String) {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date,
              a[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnknown) }
        return (size.int64Value, "\(size.int64Value):\(date.timeIntervalSince1970)")
    }
    private func loadCache() -> JSONObject {
        guard let url = try? safePath(Self.hashCache), let text = try? String(contentsOf: url, encoding: .utf8),
              let value = try? Json.parse(text), let cache = value.objectValue else { return [:] }
        return cache
    }
    private func saveCache(_ cache: JSONObject) {
        guard let url = try? safePath(Self.hashCache), let text = try? Json.stringify(cache) else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    public nonisolated static func sha256File(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
