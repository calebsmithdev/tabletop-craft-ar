// Port of quest-app/Assets/Scripts/World/BlockModels.cs at f0583fd.
// Mutable preparation owns its registry; workers receive immutable value snapshots.

/// A published copy-on-write registry. It contains no asset readers or mutable baker.
public struct BlockModelSource: IModelSource {
    public let models: [String: BakedModel]
    public init(_ models: [String: BakedModel] = [:]) { self.models = models }
    public func model(_ state: String) -> BakedModel? { models[state] }
}

/// Preparation owner, deliberately non-Sendable. Send `snapshot` to mesh workers.
public final class BlockModels {
    private var models: [String: BakedModel] = [:]
    private var prepared: Set<String> = []
    private let baker: BlockModelBaker
    public private(set) var shapeOverrides: [String: BlockShape] = [:]
    public private(set) var randomUv = RandomUv()
    public init(_ assets: any IModelAssets) { baker = BlockModelBaker(assets) }
    public var entityBoxes: Bool {
        get { baker.entityBoxes }
        set { baker.entityBoxes = newValue }
    }
    public var snapshot: BlockModelSource { BlockModelSource(models) }
    public func model(_ state: String) -> BakedModel? { models[state] }
    @discardableResult public func prepare(_ state: String, _ cubeFaces: inout [FaceKey]) -> BakedModel? {
        if prepared.contains(state) { return models[state] }
        var model = baker.bake(state)
        let byName = BlockRules.classify(state)
        if var m = model, byName != .air && byName != .fluid {
            if m.fullCube {
                randomUv.assign(&m)
                if let faces = m.cubeFaces { cubeFaces = faces }
                shapeOverrides[state] = byName == .transparentCube || !m.opaque ? .transparentCube : .cube
            } else { shapeOverrides[state] = .model }
            model = m
        }
        prepared.insert(state)
        models[state] = model
        return model
    }
}

/// Registry-local per-block UV tables. Zero means no random transform.
public struct RandomUv: Sendable {
    public static let maxTables = 63, maxEntries = 16, layerStride = 4096
    private var tables: [[UInt8]] = []
    public private(set) var version = 0
    public var count: Int { tables.count }
    public init() {}
    public mutating func reset() { tables.removeAll(); version += 1 }
    public mutating func assign(_ model: inout BakedModel) {
        guard let variants = model.variants, (2...Self.maxEntries).contains(variants.count), var faces = model.cubeFaces,
              variants.allSatisfy({ $0.fullCube && $0.cubeFaces?.count == 6 }) else { return }
        for d in 0..<6 {
            let a = variants[0].cubeFaces![d]
            var codes = [UInt8](repeating: 0,count: variants.count), same = true, any = false
            for k in variants.indices {
                let b = variants[k].cubeFaces![d]
                same = a.layer == b.layer && a.overlay == b.overlay && a.tint == b.tint
                codes[k] = Self.relative(a.uvMap,b.uvMap)
                any = any || codes[k] != 0
                if !same { break }
            }
            if same && any && faces[d].layer >= 0 { faces[d].random = register(codes) }
        }
        model.cubeFaces = faces
        // C# variant zero aliases the base model. Reproduce its observable face
        // and coverage data as a finite value, without a recursive self-reference.
        if var all = model.variants { all[0].cubeFaces = faces; model.variants = all }
    }
    public static func matrix(_ code: UInt8) -> (Int,Int,Int,Int) {
        let su = code & 2 != 0 ? -1 : 1, sv = code & 4 != 0 ? -1 : 1
        return code & 1 == 0 ? (su,0,0,sv) : (0,su,sv,0)
    }
    public static func relative(_ from: UInt8, _ to: UInt8) -> UInt8 {
        let (a00,a01,a10,a11) = matrix(from), (b00,b01,b10,b11) = matrix(to)
        let r00 = b00*a00+b01*a01, r01 = b00*a10+b01*a11, r10 = b10*a00+b11*a01, r11 = b10*a10+b11*a11
        if r00 != 0 { return (r00 < 0 ? 2 : 0) | (r11 < 0 ? 4 : 0) }
        return 1 | (r01 < 0 ? 2 : 0) | (r10 < 0 ? 4 : 0)
    }
    @discardableResult public mutating func register(_ codes: [UInt8]) -> UInt8 {
        if let i = tables.firstIndex(of: codes) { return UInt8(i+1) }
        guard tables.count < Self.maxTables, !codes.isEmpty, codes.count <= Self.maxEntries, codes.allSatisfy({ $0 < 8 }) else { return 0 }
        tables.append(codes); version += 1
        return UInt8(tables.count)
    }
    public func packed() -> [Float] {
        var result = [Float](repeating: 0,count: (Self.maxTables+1)*4)
        for (t,codes) in tables.enumerated() {
            var lo = 0, hi = 0
            for (k,code) in codes.enumerated() {
                if k < 8 { lo |= Int(code) << (3*k) } else { hi |= Int(code) << (3*(k-8)) }
            }
            result[(t+1)*4] = Float(codes.count); result[(t+1)*4+1] = Float(lo); result[(t+1)*4+2] = Float(hi)
        }
        return result
    }
    public func table(_ id: Int) -> [UInt8]? { id >= 1 && id <= tables.count ? tables[id-1] : nil }
    public static func apply(_ code: UInt8, _ u: inout Float, _ v: inout Float) {
        var tu = u-Float(0.5), tv = v-Float(0.5)
        if code & 1 != 0 { swap(&tu,&tv) }
        if code & 2 != 0 { tu = -tu }; if code & 4 != 0 { tv = -tv }
        u = tu+0.5; v = tv+0.5
    }
}

public enum BlockModelMesher {
    private static let dx = [-1,1,0,0,0,0], dy = [0,0,-1,1,0,0], dz = [0,0,0,0,-1,1]
    public static func emit(_ m: inout MeshData, _ w: WorldModel, _ x: Int, _ y: Int, _ z: Int, _ state: String,
                            _ model: BakedModel?, _ models: (any IModelSource)?) {
        guard let base = model else { return }
        let wx = w.origin.x+x, wy = w.origin.y+y, wz = w.origin.z+z
        let off = BlockRandom.offset(base,wx,wz), model = base.pick(wx,wy,wz)
        let at = SIMD3<Float>(Float(x),Float(y),Float(z))+off
        for (i,q) in model.quads.enumerated() {
            let c = Int(q.cull)
            if c >= 0 && hidden(w,x+dx[c],y+dy[c],z+dz[c],c,state,model,i,models) { continue }
            addQuad(&m,at,q,BlockShading.model(w,x,y,z,q,model.shade))
        }
    }
    private static func hidden(_ w: WorldModel, _ nx: Int, _ ny: Int, _ nz: Int, _ c: Int, _ state: String,
                               _ model: BakedModel, _ quad: Int, _ models: (any IModelSource)?) -> Bool {
        let nid = w.get(nx,ny,nz)
        if nid == .max { return false }
        let shape = w.shapeOf(nid)
        if shape == .cube { return true }
        guard shape == .model, let models else { return false }
        let ns = w.state(nid)
        if model.quads[quad].translucent && sameBlock(state,ns) { return true }
        return models.model(ns)?.covers(c ^ 1,model.cullCells,quad) ?? false
    }
    private static func sameBlock(_ a: String, _ b: String) -> Bool { a.prefix { $0 != "[" } == b.prefix { $0 != "[" } }
    public static func addQuad(_ m: inout MeshData, _ o: SIMD3<Float>, _ q: BakedQuad) { addQuad(&m,o,q,Quad4(q.color)) }
    public static func addQuad(_ m: inout MeshData, _ o: SIMD3<Float>, _ q: BakedQuad, _ colors: Quad4) {
        let s = m.verts.count
        m.verts.append(contentsOf: [o+q.p0,o+q.p1,o+q.p2,o+q.p3])
        m.uvs.append(contentsOf: [q.t0,q.t1,q.t2,q.t3])
        m.addColors(colors)
        let indices = [s,s+1,s+2,s,s+2,s+3]
        if q.translucent { m.transparent.append(contentsOf: indices) } else { m.opaque.append(contentsOf: indices) }
    }
}
