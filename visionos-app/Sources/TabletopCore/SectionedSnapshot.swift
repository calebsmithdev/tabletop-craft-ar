// Port of quest-app/Assets/Scripts/Net/SectionedSnapshot.cs at 37baed1.
public enum SnapshotError: Error, Sendable, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case let .invalid(s): s } }
}

public enum SnapshotLimits {
    public static let hardMaxBlocks = 352 * 384 * 352

    /// Allow 25% headroom over advertised limits, without exceeding the client ceiling.
    static func allocationLimit(for maxBlocks: Int?) -> Int {
        guard let maxBlocks else { return hardMaxBlocks }
        guard maxBlocks > 0 else { return 0 }
        let bounded = min(maxBlocks, hardMaxBlocks)
        return min(hardMaxBlocks, bounded + (bounded + 3) / 4)
    }
}

// Strict shared parsing for section and biome payloads: never truncate fractional wire integers.
enum SnapshotFields {
    static func ints(_ a: [JSONValue]) throws -> [Int] {
        try a.map {
            guard case let .number(n) = $0, n.isFinite, n.rounded(.towardZero) == n,
                  n >= Double(Int.min), n < Double(Int.max) else { throw SnapshotError.invalid("expected integer") }
            return Int(n)
        }
    }
    static func vector(_ o: JSONObject, _ key: String) throws -> SIMD3<Int> {
        guard let a = o.a(key) else { throw SnapshotError.invalid("missing \(key)") }
        let v = try ints(a)
        guard v.count == 3 else { throw SnapshotError.invalid("\(key) must have three integers") }
        return SIMD3(v[0],v[1],v[2])
    }
    static func integer(_ o: JSONObject, _ key: String, _ fallback: Int? = nil) throws -> Int {
        guard let v = o[key] else {
            if let fallback { return fallback }
            throw SnapshotError.invalid("missing \(key)")
        }
        return try ints([v])[0]
    }
    static func strings(_ o: JSONObject, _ key: String) throws -> [String] {
        guard let a = o.a(key), !a.isEmpty, a.count <= 65536 else { throw SnapshotError.invalid("bad \(key)") }
        return try a.map { guard case let .string(s) = $0 else { throw SnapshotError.invalid("non-string \(key)") }; return s }
    }
    static func volume(_ dims: SIMD3<Int>, maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> Int {
        guard dims.x > 0, dims.y > 0, dims.z > 0 else { throw SnapshotError.invalid("bad dims") }
        let (xy, o1) = dims.x.multipliedReportingOverflow(by: dims.y)
        let (n, o2) = xy.multipliedReportingOverflow(by: dims.z)
        guard !o1, !o2, n <= min(maxBlocks, SnapshotLimits.hardMaxBlocks) else { throw SnapshotError.invalid("bad dims or snapshot exceeds block limit") }
        return n
    }
    static func decode(_ a: [JSONValue]?, _ volume: Int, _ paletteSize: Int,
                       maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> [UInt16] {
        guard volume > 0, volume <= min(maxBlocks, SnapshotLimits.hardMaxBlocks) else { throw SnapshotError.invalid("bad volume or snapshot exceeds block limit") }
        guard let a, a.count % 2 == 0, paletteSize > 0, paletteSize <= 65536 else { throw SnapshotError.invalid("data must be [value, run] pairs") }
        let values = try ints(a)
        var count = 0
        // Validate before allocating the output, including malicious short totals with enormous dims.
        for i in stride(from: 0, to: values.count, by: 2) {
            let v = values[i], run = values[i+1]
            guard v >= 0, v < paletteSize, run > 0, run <= volume-count else { throw SnapshotError.invalid("bad run") }
            count += run
        }
        guard count == volume else { throw SnapshotError.invalid("runs cover \(count) of \(volume)") }
        var result = [UInt16](); result.reserveCapacity(volume)
        for i in stride(from: 0, to: values.count, by: 2) { result.append(contentsOf: repeatElement(UInt16(values[i]),count: values[i+1])) }
        return result
    }
}

public enum SectionedSnapshot {
    public static let encoding = "sections_v1"
    public static let cap = "sections_v1"
    public static func assemble(_ parts: [JSONObject], current: WorldModel? = nil,
                                maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> ChunkSnapshot {
        var listed: [SIMD3<Int>] = []
        return try assemble(parts,current: current,listed: &listed,maxBlocks: maxBlocks)
    }
    public static func assemble(_ parts: [JSONObject], current: WorldModel? = nil, listed: inout [SIMD3<Int>],
                                maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> ChunkSnapshot {
        guard let first = parts.first else { throw SnapshotError.invalid("no parts") }
        guard first.s("order") == "yzx", first.s("encoding") == encoding else { throw SnapshotError.invalid("unsupported order/encoding") }
        guard let world = first.s("world"), !world.isEmpty else { throw SnapshotError.invalid("missing world") }
        let dims = try SnapshotFields.vector(first,"dims"), origin = try SnapshotFields.vector(first,"origin")
        let volume = try SnapshotFields.volume(dims,maxBlocks: maxBlocks), palette = try SnapshotFields.strings(first,"palette")
        let id = try SnapshotFields.integer(first,"snapshot_id"), total = try SnapshotFields.integer(first,"parts",1)
        guard total >= 1, parts.count == total else { throw SnapshotError.invalid("wrong part count") }
        let base = first.o("base"), lightObject = first.o("light")
        if first["base"] != nil && first["base"] != .null && base == nil { throw SnapshotError.invalid("bad base") }
        if first["light"] != nil && first["light"] != .null && lightObject == nil { throw SnapshotError.invalid("bad light") }
        if let lightObject {
            guard lightObject.s("encoding") == "rle_v1", lightObject.b("in_sections") else { throw SnapshotError.invalid("unsupported section light") }
        }
        var shift = SIMD3<Int>.zero
        if let base {
            shift = try SnapshotFields.vector(base,"shift")
            guard let cur = current, cur.loaded, cur.snapshotId == (try SnapshotFields.integer(base,"snapshot_id")), cur.world == first.s("world") else { throw SnapshotError.invalid("unknown base snapshot/world") }
            for a in 0..<3 {
                guard shift[a] % 16 == 0, origin[a].subtractingReportingOverflow(cur.origin[a]).overflow == false,
                      origin[a] - cur.origin[a] == shift[a], shift[a] < cur.dims[a],
                      shift[a].addingReportingOverflow(dims[a]).overflow == false, shift[a] + dims[a] > 0 else { throw SnapshotError.invalid("invalid base shift/overlap") }
            }
            guard palette.starts(with: cur.palette) else { throw SnapshotError.invalid("palette prefix differs") }
            guard cur.grid.count == (try SnapshotFields.volume(cur.dims)) else { throw SnapshotError.invalid("bad base grid") }
            if lightObject != nil && cur.light?.count != cur.grid.count { throw SnapshotError.invalid("delta with light against a snapshot without light") }
        }
        let n = SectionPlan.sections(dims)
        // Decode and validate coverage before allocating the full grid.
        var decoded: [(SIMD3<Int>, [UInt16], [UInt16]?)] = []
        var keys: Set<SIMD3<Int>> = []
        for (pi,m) in parts.enumerated() {
            guard try SnapshotFields.integer(m,"snapshot_id") == id,
                  try SnapshotFields.integer(m,"part",-1) == pi,
                  try SnapshotFields.integer(m,"parts",1) == total,
                  m.s("world") == first.s("world"), m.s("order") == "yzx", m.s("encoding") == encoding,
                  try SnapshotFields.vector(m,"origin") == origin, try SnapshotFields.vector(m,"dims") == dims,
                  try SnapshotFields.strings(m,"palette") == palette,
                  m.o("base") == base, m.o("light") == lightObject else { throw SnapshotError.invalid("inconsistent/out-of-order parts") }
            for field in ["base", "light", "biomes"] where m[field] != nil && m[field] != .null && m.o(field) == nil {
                throw SnapshotError.invalid("bad \(field) object")
            }
            if pi > 0, m["biomes"] != nil && m["biomes"] != .null { throw SnapshotError.invalid("biomes only allowed on part zero") }
            guard let sections = m.a("sections") else { throw SnapshotError.invalid("missing sections") }
            for e in sections {
                guard case let .object(sec) = e else { throw SnapshotError.invalid("section is not an object") }
                let k = try SnapshotFields.vector(sec,"s")
                guard SectionPlan.contains(k,n), keys.insert(k).inserted else { throw SnapshotError.invalid("section key out of range or listed twice") }
                let size = SIMD3(min(16,dims.x-k.x*16),min(16,dims.y-k.y*16),min(16,dims.z-k.z*16))
                let count = size.x*size.y*size.z
                let data = try SnapshotFields.decode(sec.a("data"),count,palette.count,maxBlocks: maxBlocks)
                let light = lightObject == nil ? nil : try SnapshotFields.decode(sec.a("light"),count,256,maxBlocks: maxBlocks)
                decoded.append((k,data,light))
            }
        }
        for k in SectionPlan.keys(n) where !keys.contains(k) {
            guard base != nil, let cur = current else { throw SnapshotError.invalid("section missing from full snapshot") }
            for a in 0..<3 {
                let lo = k[a]*16 + shift[a], hi = min(dims[a],k[a]*16+16) + shift[a]
                guard lo >= 0, hi <= cur.dims[a] else { throw SnapshotError.invalid("unlisted section outside base") }
            }
        }
        let biomes = try BiomeGrid.from(first.o("biomes"),maxBlocks: maxBlocks)
        var grid = [UInt16](repeating: 0,count: volume)
        var light: [UInt8]? = lightObject == nil ? nil : [UInt8](repeating: 0,count: volume)
        if base != nil, let cur = current {
            let x0 = max(0,-shift.x), x1 = min(dims.x,cur.dims.x-shift.x)
            if x1 > x0 { for y in 0..<dims.y { for z in 0..<dims.z {
                let oy = y+shift.y, oz = z+shift.z
                guard oy >= 0, oy < cur.dims.y, oz >= 0, oz < cur.dims.z else { continue }
                for x in x0..<x1 {
                    let ni = (y*dims.z+z)*dims.x+x, oi = (oy*cur.dims.z+oz)*cur.dims.x+x+shift.x
                    grid[ni] = cur.grid[oi]
                    if light != nil { light![ni] = cur.light![oi] }
                }
            } } }
        }
        for (k,data,sl) in decoded {
            let b = k &* SIMD3(repeating: 16), sx = min(16,dims.x-b.x), sy = min(16,dims.y-b.y), sz = min(16,dims.z-b.z)
            var at = 0
            for y in 0..<sy { for z in 0..<sz { for x in 0..<sx {
                let i = ((b.y+y)*dims.z+b.z+z)*dims.x+b.x+x
                grid[i] = data[at]; if let sl { light![i] = UInt8(sl[at]) }; at += 1
            } } }
        }
        listed.append(contentsOf: decoded.map { $0.0 })
        return ChunkSnapshot(snapshotId: id,world: world,origin: origin,dims: dims,palette: palette,grid: grid,light: light,biomes: biomes)
    }
}
