// Engine-free port of Net/AssetProtocol.cs; PROTOCOL.md "Asset delivery".
import Foundation

public struct AssetFile: Sendable, Equatable {
    public let name: String
    public let size: Int64
    public let sha256: String
    public init(name: String, size: Int64, sha256: String) {
        self.name = name; self.size = size; self.sha256 = sha256
    }
}

public enum AssetProtocol {
    public static let cap = "assets_v1", type = "assets"
    public static let names: Set<String> = ["pack.zip", "entity_models.json", "sounds.zip"]
    public static let maxChunk = 1 << 20
    public static let maxSize = Int64(Int32.max)

    public struct Offer: Sendable, Equatable {
        public let files: [AssetFile]
        public let chunk: Int
        public let state: String
        public let note: String
    }
    public struct Chunk: Sendable, Equatable {
        public let name: String
        public let offset: Int64
        public let data: Data
    }
    public static func parseOffer(_ message: JSONObject) -> Offer {
        var seen = Set<String>()
        let files = (message.a("files") ?? []).compactMap { value -> AssetFile? in
            guard let f = value.objectValue, let name = f.s("name"), names.contains(name),
                  let hash = f.s("sha256"), hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let number = f["size"]?.numberValue, let size = Int64(exactly: number),
                  size > 0, size <= maxSize, seen.insert(name).inserted else { return nil }
            return AssetFile(name: name, size: size, sha256: hash.lowercased())
        }
        let rawChunk = message["chunk"]?.numberValue ?? 262144
        let chunk = rawChunk.isFinite ? Int(max(1024, min(Double(maxChunk), rawChunk))) : 262144
        return Offer(files: files, chunk: chunk,
                     state: message.s("state") ?? "", note: message.s("note") ?? "")
    }
    public static func get(name: String, offset: Int64, length: Int) -> JSONObject {
        ["type": "asset_get", "name": .string(name), "offset": .number(Double(offset)), "length": .number(Double(length))]
    }
    public static func parseChunk(_ data: Data) -> Chunk? {
        // Data can have a nonzero startIndex when supplied as a slice.
        let b = Array(data)
        guard b.count >= 15, b.prefix(4).elementsEqual("TTA1".utf8) else { return nil }
        let n = Int(b[4]), start = 13 + n
        guard (1...64).contains(n), b.count > start, b.count - start <= maxChunk,
              b[5..<(5 + n)].allSatisfy({ $0 < 128 }),
              let name = String(bytes: b[5..<(5 + n)], encoding: .ascii) else { return nil }
        var offset: UInt64 = 0
        for byte in b[(5 + n)..<start] { offset = (offset << 8) | UInt64(byte) }
        guard offset <= UInt64(Int64.max) else { return nil }
        return Chunk(name: name, offset: Int64(offset), data: Data(b[start...]))
    }
    /// Test/server utility. Invalid header inputs return nil.
    public static func frame(name: String, offset: Int64, data: Data) -> Data? {
        let nameBytes = Array(name.utf8)
        guard (1...64).contains(nameBytes.count), nameBytes.allSatisfy({ $0 < 128 }), offset >= 0,
              !data.isEmpty, data.count <= maxChunk else { return nil }
        var result = Data("TTA1".utf8)
        result.append(UInt8(nameBytes.count)); result.append(contentsOf: nameBytes)
        for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: UInt64(offset) >> shift)) }
        result.append(data)
        return result
    }
}
