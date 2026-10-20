// Port of quest-app/Assets/Scripts/World/WorldModel.cs at 37baed1.
// Value-owned snapshot state: pass copies to mesh workers, serialize mutation in its owner.
public struct WorldModel: Sendable {
    public static let section = 16
    public var snapshotId = -1
    public var world = ""
    public var origin = SIMD3<Int>.zero
    public var dims = SIMD3<Int>.zero
    public var palette: [String] = []
    public var grid: [UInt16] = []
    public var light: [UInt8]?
    public var biomes: BiomeGrid?
    public var dirtySections: Set<SIMD3<Int>> = []
    public private(set) var paletteEpoch = 0
    public private(set) var edits = 0
    private var shapes: [BlockShape] = []
    public init() {}
    public var loaded: Bool { snapshotId >= 0 }
    public var sectionCount: SIMD3<Int> { SectionPlan.sections(dims) }
    @inline(__always) public func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (y * dims.z + z) * dims.x + x }
    @inline(__always) public func inBounds(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        x >= 0 && y >= 0 && z >= 0 && x < dims.x && y < dims.y && z < dims.z
    }
    @inline(__always) public func get(_ x: Int, _ y: Int, _ z: Int) -> UInt16 { inBounds(x,y,z) ? grid[index(x,y,z)] : .max }
    public func state(_ id: UInt16) -> String { Int(id) < palette.count ? palette[Int(id)] : "minecraft:air" }
    @inline(__always) public func shapeOf(_ id: UInt16) -> BlockShape { Int(id) < shapes.count ? shapes[Int(id)] : BlockRules.shape(state(id)) }
    public mutating func load(_ snapshot: ChunkSnapshot) { applySnapshot(snapshot) }
    public mutating func applySnapshot(_ s: ChunkSnapshot) {
        snapshotId = s.snapshotId; world = s.world; origin = s.origin; dims = s.dims
        if !s.palette.starts(with: palette) { paletteEpoch += 1 }
        palette = s.palette; grid = s.grid; light = s.light; biomes = s.biomes
        shapes = palette.map(BlockRules.shape)
        dirtySections = Set(SectionPlan.keys(sectionCount))
    }
    @discardableResult public mutating func apply(_ message: JSONObject) -> Bool { applyBlockUpdate(message) }
    @discardableResult public mutating func applyBlockUpdate(_ m: JSONObject) -> Bool {
        guard m.i("snapshot_id", -2) == snapshotId else { return false }
        if let add = m.a("palette_add") {
            for case let .string(s) in add { palette.append(s); shapes.append(BlockRules.shape(s)) }
        }
        for value in m.a("changes") ?? [] {
            guard case let .array(a) = value, let c = try? SnapshotFields.ints(a), c.count == 4,
                  inBounds(c[0],c[1],c[2]), c[3] >= 0, c[3] < palette.count, c[3] < 65536 else { continue }
            grid[index(c[0],c[1],c[2])] = UInt16(c[3]); markDirty(c[0],c[1],c[2])
        }
        if light != nil {
            for value in m.a("light") ?? [] {
                guard case let .array(a) = value, let c = try? SnapshotFields.ints(a), c.count == 4,
                      inBounds(c[0],c[1],c[2]), (0...255).contains(c[3]) else { continue }
                let i = index(c[0],c[1],c[2])
                guard i < light!.count else { continue }
                light![i] = UInt8(c[3]); markDirty(c[0],c[1],c[2])
            }
        }
        return true
    }
    public mutating func setLocal(_ x: Int, _ y: Int, _ z: Int, _ id: UInt16) {
        guard inBounds(x,y,z), Int(id) < palette.count else { return }
        grid[index(x,y,z)] = id; markDirty(x,y,z)
    }
    mutating func markDirty(_ x: Int, _ y: Int, _ z: Int) {
        edits += 1
        let p = SIMD3(x,y,z), s = p / SIMD3(repeating: Self.section), n = sectionCount
        var lo = s, hi = s
        for a in 0..<3 {
            if p[a] % Self.section == 0 && s[a] > 0 { lo[a] -= 1 }
            if p[a] % Self.section == Self.section - 1 && s[a] + 1 < n[a] { hi[a] += 1 }
        }
        for x in lo.x...hi.x { for y in lo.y...hi.y { for z in lo.z...hi.z { dirtySections.insert(SIMD3(x,y,z)) } } }
    }
}

public struct PaletteTable<T: Sendable>: Sendable {
    public private(set) var items: [T] = []
    public private(set) var computed = 0
    private var epoch = -1
    public init() {}
    @discardableResult public mutating func update(_ w: WorldModel, _ make: (String) -> T) -> Bool {
        let from = epoch == w.paletteEpoch && items.count <= w.palette.count ? items.count : 0
        if from == w.palette.count && epoch == w.paletteEpoch { return false }
        items = Array(items.prefix(from)) + w.palette.dropFirst(from).map(make)
        computed += w.palette.count - from; epoch = w.paletteEpoch
        return true
    }
    public mutating func reset() { items = []; epoch = -1 }
}
