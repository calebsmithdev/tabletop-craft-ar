// Port of quest-app/Assets/Scripts/Net/Json.cs at 37baed1.
import Foundation

public typealias JSONObject = [String: JSONValue]
public typealias Int3 = SIMD3<Int>
public typealias Float3 = SIMD3<Float>

/// Protocol numbers are doubles, as in the engine-free C# parser. No Any crosses actors.
public enum JSONValue: Sendable, Equatable {
    case object(JSONObject), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public var objectValue: JSONObject? { if case .object(let v) = self { v } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var numberValue: Double? { if case .number(let v) = self { v } else { nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var intValue: Int? { numberValue.flatMap(Int.init(exactly:)) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public struct JsonError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Json {
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        let value = try parser.value(depth: 0)
        parser.ws()
        guard parser.index == parser.bytes.count else { throw JsonError("trailing data") }
        return value
    }

    public static func stringify(_ value: JSONValue) throws -> String {
        var result = ""
        try write(value, into: &result, depth: 0)
        return result
    }

    public static func stringify(_ value: JSONObject) throws -> String { try stringify(.object(value)) }
    public static func write(_ value: JSONValue) throws -> String { try stringify(value) }
    public static func write(_ value: JSONObject) throws -> String { try stringify(value) }

    public static func ints(_ values: [JSONValue]?) throws -> [Int] {
        guard let values else { throw JsonError("expected integer array") }
        return try values.map {
            guard let n = $0.intValue else { throw JsonError("expected integer") }
            return n
        }
    }

    public static func doubles(_ values: [JSONValue]?) throws -> [Double] {
        guard let values else { throw JsonError("expected number array") }
        return try values.map {
            guard let n = $0.numberValue else { throw JsonError("expected number") }
            return n
        }
    }

    private static func write(_ value: JSONValue, into s: inout String, depth: Int) throws {
        guard depth < 256 else { throw JsonError("JSON nesting limit") }
        switch value {
        case .null: s += "null"
        case .bool(let b): s += b ? "true" : "false"
        case .number(let n):
            guard n.isFinite else { throw JsonError("non-finite JSON number") }
            // Integer tokens are required by strict peers for v/seq and other wire integers.
            // Keep Swift's shortest round-trip representation for fractional/large doubles.
            if abs(n) < 9_007_199_254_740_992, n.rounded(.towardZero) == n {
                s += String(Int64(n))
            } else {
                s += String(n)
            }
        case .string(let v):
            s += "\""
            for scalar in v.unicodeScalars {
                switch scalar.value {
                case 34: s += "\\\""
                case 92: s += "\\\\"
                case 0..<32: s += String(format: "\\u%04x", scalar.value)
                default: s.unicodeScalars.append(scalar)
                }
            }
            s += "\""
        case .array(let a):
            s += "["
            for (i, v) in a.enumerated() {
                if i > 0 { s += "," }
                try write(v, into: &s, depth: depth + 1)
            }
            s += "]"
        case .object(let o):
            s += "{"
            // Stable output makes fixtures and link logs easy to compare; object order has no wire meaning.
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { s += "," }
                try write(.string(key), into: &s, depth: depth + 1)
                s += ":"
                if let v = o[key] { try write(v, into: &s, depth: depth + 1) }
            }
            s += "}"
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func ws() {
            while let c = current, c == 32 || c == 9 || c == 10 || c == 13 { index += 1 }
        }
        mutating func consume(_ c: UInt8) -> Bool {
            guard current == c else { return false }
            index += 1
            return true
        }
        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 256 else { throw JsonError("JSON nesting limit") }
            ws()
            switch current {
            case 123:
                index += 1; ws()
                var object: JSONObject = [:]
                if consume(125) { return .object(object) }
                repeat {
                    ws()
                    let key = try str()
                    ws()
                    guard consume(58) else { throw JsonError("expected :") }
                    object[key] = try value(depth: depth + 1)
                    ws()
                    if consume(125) { return .object(object) }
                    guard consume(44) else { throw JsonError("expected , or }") }
                } while true
            case 91:
                index += 1; ws()
                var array: [JSONValue] = []
                if consume(93) { return .array(array) }
                repeat {
                    array.append(try value(depth: depth + 1))
                    ws()
                    if consume(93) { return .array(array) }
                    guard consume(44) else { throw JsonError("expected , or ]") }
                } while true
            case 34: return .string(try str())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case let c? where c == 45 || (48...57).contains(c): return .number(try number())
            default: throw JsonError("bad token at \(index)")
            }
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 {
                guard consume(byte) else { throw JsonError("bad literal") }
            }
        }
        mutating func str() throws -> String {
            guard consume(34) else { throw JsonError("expected string") }
            var result: [UInt8] = []
            while let c = current {
                index += 1
                if c == 34 {
                    guard let s = String(bytes: result, encoding: .utf8) else { throw JsonError("invalid UTF-8") }
                    return s
                }
                guard c >= 32 else { throw JsonError("unescaped control character") }
                if c != 92 { result.append(c); continue }
                guard let escape = current else { throw JsonError("unfinished escape") }
                index += 1
                switch escape {
                case 34, 47, 92: result.append(escape)
                case 98: result.append(8)
                case 102: result.append(12)
                case 110: result.append(10)
                case 114: result.append(13)
                case 116: result.append(9)
                case 117:
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard consume(92), consume(117) else { throw JsonError("missing low surrogate") }
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw JsonError("bad low surrogate") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + low - 0xDC00
                    }
                    guard let unicode = Unicode.Scalar(scalar) else { throw JsonError("invalid unicode scalar") }
                    result.append(contentsOf: String(unicode).utf8)
                default: throw JsonError("invalid escape")
                }
            }
            throw JsonError("unterminated string")
        }
        mutating func hex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let c = current else { throw JsonError("short unicode escape") }
                let digit: UInt8
                switch c {
                case 48...57: digit = c - 48
                case 65...70: digit = c - 55
                case 97...102: digit = c - 87
                default: throw JsonError("bad unicode escape")
                }
                index += 1; value = value * 16 + UInt32(digit)
            }
            return value
        }
        mutating func number() throws -> Double {
            let start = index
            let negative = consume(45)
            // RLE and light arrays contain mostly small integers. Match Json.cs: scan without
            // a substring or boxed number; fall back only for fractions/exponents/large integers.
            var end = index
            var integer: Int64 = 0
            while end < bytes.count, (48...57).contains(bytes[end]), end - index < 15 {
                integer = integer * 10 + Int64(bytes[end] - 48)
                end += 1
            }
            if end > index, !(bytes[index] == 48 && end - index > 1),
               end == bytes.count || !(bytes[end] == 46 || bytes[end] == 101 || bytes[end] == 69 || (48...57).contains(bytes[end])) {
                index = end
                return negative ? -Double(integer) : Double(integer)
            }
            if !consume(48) {
                guard let c = current, (49...57).contains(c) else { throw JsonError("bad number") }
                while let c = current, (48...57).contains(c) { index += 1 }
            }
            if consume(46) {
                let first = index
                while let c = current, (48...57).contains(c) { index += 1 }
                guard index > first else { throw JsonError("bad fraction") }
            }
            if consume(101) || consume(69) {
                if !consume(43) { _ = consume(45) }
                let first = index
                while let c = current, (48...57).contains(c) { index += 1 }
                guard index > first else { throw JsonError("bad exponent") }
            }
            guard let n = Double(String(decoding: bytes[start..<index], as: UTF8.self)), n.isFinite else {
                throw JsonError("bad number")
            }
            return n
        }
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func s(_ key: String) -> String? { self[key]?.stringValue }
    func d(_ key: String, _ fallback: Double = 0) -> Double { self[key]?.numberValue ?? fallback }
    func i(_ key: String, _ fallback: Int = 0) -> Int {
        guard let n = self[key]?.numberValue, n.isFinite else { return fallback }
        return Int(exactly: n.rounded(.towardZero)) ?? fallback
    }
    func b(_ key: String, _ fallback: Bool = false) -> Bool { self[key]?.boolValue ?? fallback }
    func a(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }
    func o(_ key: String) -> JSONObject? { self[key]?.objectValue }
}
