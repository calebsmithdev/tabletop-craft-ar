// Port of quest-app/Assets/Scripts/World/BiomeColors.cs (BiomeGrid) at b826247.
public struct BiomeGrid: Sendable {
    public var qOrigin: SIMD3<Int>
    public var qDims: SIMD3<Int>
    public var palette: [String]
    public var climate: [[Double]?]?
    public var cells: [UInt16]
    public init(qOrigin: SIMD3<Int> = .zero, qDims: SIMD3<Int> = .zero, palette: [String] = [], climate: [[Double]?]? = nil, cells: [UInt16] = []) {
        self.qOrigin = qOrigin; self.qDims = qDims; self.palette = palette; self.climate = climate; self.cells = cells
    }
    public static func from(_ o: JSONObject?, maxBlocks: Int = SnapshotLimits.hardMaxBlocks) throws -> BiomeGrid? {
        guard let o else { return nil }
        guard o.i("res") == 4 && o.s("encoding") == "rle_palette_v1" else { throw SnapshotError.invalid("unsupported biome res/encoding") }
        let origin = try SnapshotFields.vector(o,"q_origin"), dims = try SnapshotFields.vector(o,"q_dims")
        let volume = try SnapshotFields.volume(dims,maxBlocks: maxBlocks)
        let palette = try SnapshotFields.strings(o,"palette")
        var climate: [[Double]?]?
        if let c = o.a("climate"), c.count == palette.count {
            climate = c.map { value in
                guard case let .array(a) = value, a.count >= 2 else { return nil }
                let values = a.compactMap { v -> Double? in if case let .number(d) = v { return d }; return nil }
                return values.count == a.count ? values : nil
            }
        }
        return BiomeGrid(qOrigin: origin, qDims: dims, palette: palette, climate: climate,
                         cells: try SnapshotFields.decode(o.a("data"), volume, palette.count,maxBlocks: maxBlocks))
    }
    public func at(_ wx: Int, _ wy: Int, _ wz: Int) -> Int {
        let x = max(0,min(qDims.x-1,(wx >> 2)-qOrigin.x)), y = max(0,min(qDims.y-1,(wy >> 2)-qOrigin.y)), z = max(0,min(qDims.z-1,(wz >> 2)-qOrigin.z))
        return Int(cells[(y*qDims.z+z)*qDims.x+x])
    }
}
