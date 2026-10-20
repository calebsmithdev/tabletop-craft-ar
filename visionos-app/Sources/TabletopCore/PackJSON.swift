// Ordered asset-JSON adapter for BlockModelBaker.cs / ResourcePackAtlas.cs at f7d4a0f.
// JSONObject remains the existing Sendable value type. Private per-object metadata
// preserves source member order across asset caching and snapshot copies.
import Foundation

public enum PackJSON {
    private static let orderKey = "\u{0}tabletop:member-order"

    public static func parse(_ text: String) throws -> JSONObject {
        let value = try Json.parse(text)
        var reader = OrderReader(bytes: Array(text.utf8))
        guard let object = try reader.annotate(value).objectValue else { throw JsonError("expected asset JSON object") }
        return object
    }
    public static func parse(_ data: Data) throws -> JSONObject {
        guard let text = String(data: data,encoding: .utf8) else { throw JsonError("invalid UTF-8") }
        return try parse(text)
    }
    /// Use this for source-order-sensitive asset traversal. Plain synthetic
    /// dictionaries have no source order and use a deterministic key order.
    public static func keys(_ object: JSONObject) -> [String] {
        if let order = object[orderKey]?.arrayValue { return order.compactMap(\.stringValue) }
        return object.keys.filter { $0 != orderKey }.sorted()
    }
    public static func members(_ object: JSONObject) -> [(String,JSONValue)] {
        keys(object).compactMap { key in object[key].map { (key,$0) } }
    }

    private struct OrderReader {
        let bytes: [UInt8]
        var index = 0
        mutating func ws() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func stringToken() -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { index += 1 }
                else if byte == 34 { break }
            }
            return String(decoding: bytes[start..<index],as: UTF8.self)
        }
        mutating func annotate(_ value: JSONValue) throws -> JSONValue {
            ws()
            switch value {
            case .object(let original):
                index += 1; ws()
                var object: JSONObject = [:], order: [String] = []
                if bytes[index] == 125 { index += 1 }
                else {
                    while true {
                        let token = stringToken()
                        guard let key = try Json.parse(token).stringValue, key != PackJSON.orderKey else { throw JsonError("reserved asset JSON key") }
                        ws(); index += 1
                        // Json.parse has already validated the syntax. Duplicate keys
                        // use the final value, retaining their first insertion position.
                        guard let child = original[key] else { throw JsonError("missing asset JSON member") }
                        // A duplicate can change type, so parse this occurrence before
                        // annotating rather than traversing the final dictionary value.
                        let start = index
                        skipValue()
                        let end = index
                        index = start
                        let occurrence = try Json.parse(String(decoding: bytes[start..<end],as: UTF8.self))
                        _ = child
                        object[key] = try annotate(occurrence)
                        if !order.contains(key) { order.append(key) }
                        ws()
                        if bytes[index] == 125 { index += 1; break }
                        index += 1; ws()
                    }
                }
                object[PackJSON.orderKey] = .array(order.map(JSONValue.string))
                return .object(object)
            case .array(let array):
                index += 1; ws()
                var result: [JSONValue] = []
                for (i,child) in array.enumerated() {
                    if i != 0 { index += 1 }
                    result.append(try annotate(child)); ws()
                }
                index += 1
                return .array(result)
            case .string:
                _ = stringToken(); return value
            default:
                skipValue(); return value
            }
        }
        mutating func skipValue() {
            ws()
            if bytes[index] == 34 { _ = stringToken(); return }
            if bytes[index] == 123 || bytes[index] == 91 {
                let close: UInt8 = bytes[index] == 123 ? 125 : 93
                index += 1; ws()
                while bytes[index] != close {
                    if bytes[index] == 34 { _ = stringToken() }
                    else if bytes[index] == 123 || bytes[index] == 91 { skipValue() }
                    else { index += 1 }
                    ws()
                }
                index += 1; return
            }
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
        }
    }
}
