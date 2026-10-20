// Port of quest-app/Assets/Scripts/World/GreedyMesher.cs at f0583fd.
// CPU textured path. Coordinates and winding remain in the tabletop frame.
public enum TintKind: UInt8, Sendable { case none, grass, foliage, dryFoliage, water }
public struct FaceKey: Equatable, Sendable {
    public var layer = 0
    public var color = Color32(0,0,0,0)
    public var transparent = false
    public var tint: TintKind = .none
    public var uvMap: UInt8 = 0
    public var overlay = 0
    public var overlayColor = Color32(0,0,0,0)
    public var overlayTint: TintKind = .none
    public var overlayUvMap: UInt8 = 0
    public var random: UInt8 = 0
    public var shade: UInt8 = 0
    public var light: UInt8 = 0
    public init(layer: Int = 0, color: Color32 = Color32(0,0,0,0), transparent: Bool = false) {
        self.layer = layer; self.color = color; self.transparent = transparent
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.layer == b.layer && a.color == b.color && a.transparent == b.transparent && a.tint == b.tint && a.uvMap == b.uvMap && a.random == b.random && a.shade == b.shade && a.light == b.light && a.overlay == b.overlay && (a.overlay == 0 || (a.overlayColor == b.overlayColor && a.overlayTint == b.overlayTint && a.overlayUvMap == b.overlayUvMap))
    }
    public func overlayKey() -> FaceKey {
        guard overlay != 0 else { return FaceKey() }
        var k = FaceKey(layer: overlay-1,color: overlayColor,transparent: transparent)
        k.tint = overlayTint; k.uvMap = overlayUvMap; k.shade = shade
        return k
    }
}
public protocol IFaceSource: Sendable {
    /// 0=-X, 1=+X, 2=-Y, 3=+Y, 4=-Z, 5=+Z.
    func face(_ state: String, _ dir: Int) -> FaceKey
}
public struct FlatFaceSource: IFaceSource {
    public init() {}
    public func face(_ state: String, _ dir: Int) -> FaceKey { FaceKey(layer: -1,color: BlockRules.flatColor(state)) }
}
public struct MeshData: Sendable {
    public var verts: [SIMD3<Float>] = []
    public var uvs: [SIMD3<Float>] = []
    public var colors: [Color32] = []
    public var opaque: [Int] = []
    public var transparent: [Int] = []
    public var waterBack: [Int] = []
    public var light: [UInt8] = []
    public init() {}
    public mutating func addColors(_ q: Quad4) {
        colors.append(contentsOf: [q.c0,q.c1,q.c2,q.c3])
        light.append(contentsOf: [q.l0,q.l1,q.l2,q.l3])
    }
    public mutating func copyColor(_ i: Int) {
        colors.append(colors[i]); light.append(i < light.count ? light[i] : 240)
    }
    public mutating func clear() {
        verts.removeAll(keepingCapacity: true); uvs.removeAll(keepingCapacity: true); colors.removeAll(keepingCapacity: true)
        opaque.removeAll(keepingCapacity: true); transparent.removeAll(keepingCapacity: true); waterBack.removeAll(keepingCapacity: true); light.removeAll(keepingCapacity: true)
    }
}
public enum GreedyMesher {
    static let dirs: [SIMD3<Int>] = [SIMD3(-1,0,0),SIMD3(1,0,0),SIMD3(0,-1,0),SIMD3(0,1,0),SIMD3(0,0,-1),SIMD3(0,0,1)]
    public static func build(_ w: WorldModel, _ section: SIMD3<Int>, _ faces: any IFaceSource, _ m: inout MeshData, leavesInner: Bool = true) {
        m.clear()
        let b0 = section &* SIMD3(repeating: 16)
        let size = SIMD3(min(16,w.dims.x-b0.x),min(16,w.dims.y-b0.y),min(16,w.dims.z-b0.z))
        guard b0.x >= 0, b0.y >= 0, b0.z >= 0, size.x > 0, size.y > 0, size.z > 0 else { return }
        // Section + one-cell border, palette shape and face tables: no string work in the hot cell loop.
        let p = 18
        func pad(_ x: Int, _ y: Int, _ z: Int) -> Int { ((y+1)*p+z+1)*p+x+1 }
        var ids = ContiguousArray<UInt16>(repeating: .max,count: p*p*p)
        var shapes = ContiguousArray<BlockShape>(repeating: .air,count: p*p*p)
        var cubes = 0
        for y in -1...16 { for z in -1...16 { for x in -1...16 {
            let id = w.get(b0.x+x,b0.y+y,b0.z+z), i = pad(x,y,z)
            ids[i] = id
            if w.inBounds(b0.x+x,b0.y+y,b0.z+z) { shapes[i] = w.shapeOf(id) }
            if x >= 0 && y >= 0 && z >= 0 && x < size.x && y < size.y && z < size.z && (shapes[i] == .cube || shapes[i] == .transparentCube) { cubes += 1 }
        } } }
        guard cubes > 0 else { return }
        var keyCache: [Int: FaceKey] = [:]
        let leaves = w.palette.map { BlockRules.path($0).hasSuffix("_leaves") }
        var mask = ContiguousArray<FaceKey?>(repeating: nil,count: 256)
        var colors = [Quad4?](repeating: nil,count: 256)
        var overlays = [Quad4?](repeating: nil,count: 256)
        let strides = [1,p*p,p]
        for dir in 0..<6 {
            let axis = dir/2, ua = (axis+1)%3, va = (axis+2)%3
            let sa = strides[axis], su = strides[ua], sv = strides[va], no = dir & 1 == 1 ? sa : -sa
            for d in 0..<size[axis] {
                for v in 0..<size[va] { for u in 0..<size[ua] {
                    let k = u+v*16, i = pad(0,0,0)+d*sa+v*sv+u*su, shape = shapes[i]
                    mask[k] = nil
                    guard shape == .cube || shape == .transparentCube else { continue }
                    let ni = i+no, id = ids[i], nid = ids[ni]
                    if nid != .max {
                        if shapes[ni] == .cube { continue }
                        let leaf = Int(id) < leaves.count && leaves[Int(id)]
                        if nid == id && shape != .cube && !(leavesInner && leaf) { continue }
                    }
                    let cacheId = Int(id)*6+dir
                    var key: FaceKey
                    if let cached = keyCache[cacheId] { key = cached }
                    else { key = faces.face(w.state(id),dir); keyCache[cacheId] = key }
                    key.transparent = key.transparent || shape != .cube; mask[k] = key
                    var c = SIMD3<Int>.zero; c[axis] = d; c[ua] = u; c[va] = v; c &+= b0
                    colors[k] = BlockShading.faceCorners(w,key,c.x,c.y,c.z,dir)
                    overlays[k] = key.overlay == 0 ? nil : BlockShading.faceCorners(w,key.overlayKey(),c.x,c.y,c.z,dir)
                } }
                for v in 0..<size[va] {
                    var u = 0
                    while u < size[ua] {
                        let k = u+v*16
                        guard let key = mask[k] else { u += 1; continue }
                        let col = colors[k]!, over = overlays[k]
                        var width = 1
                        if col.same(0,1) && col.same(3,2) && (over == nil || (over!.same(0,1) && over!.same(3,2))) {
                            while u+width < size[ua] && mask[k+width] == key && colors[k+width] == col && overlays[k+width] == over { width += 1 }
                        }
                        var height = 1
                        var ok = col.same(0,3) && col.same(1,2) && (over == nil || (over!.same(0,3) && over!.same(1,2)))
                        while v+height < size[va] && ok {
                            for i in 0..<width {
                                let j = u+i+(v+height)*16
                                if mask[j] != key || colors[j] != col || overlays[j] != over { ok = false; break }
                            }
                            if ok { height += 1 }
                        }
                        var corners: [SIMD3<Float>] = []
                        for (cu,cv) in [(u,v),(u+width,v),(u+width,v+height),(u,v+height)] {
                            var c = SIMD3<Float>(Float(b0.x),Float(b0.y),Float(b0.z))
                            c[axis] += Float(d + (dir & 1 == 1 ? 1 : 0)); c[ua] += Float(cu); c[va] += Float(cv); corners.append(c)
                        }
                        func luma(_ c: Color32) -> Int { Int(c.r)*2+Int(c.g)*5+Int(c.b) }
                        let flip = luma(col.c1)+luma(col.c3) > luma(col.c0)+luma(col.c2)
                        emit(&m,corners,key,dir & 1 == 1,false,dir,b0,col,flip)
                        if let over { emit(&m,corners,key.overlayKey(),dir & 1 == 1,false,dir,b0,over,flip) }
                        for j in 0..<height { for i in 0..<width { mask[u+i+(v+j)*16] = nil } }
                        u += width
                    }
                }
            }
        }
    }
    /// M1 app compatibility. The explicit face-source overload opts into M3 lighting.
    public static func build(_ w: WorldModel, _ section: SIMD3<Int>, _ m: inout MeshData) {
        var flat = w; flat.light = nil; flat.tints = nil
        build(flat,section,FlatFaceSource(),&m)
    }
    public static func buildSpecials(_ w: WorldModel, _ section: SIMD3<Int>, _ faces: any IFaceSource, _ m: inout MeshData, includeFluids: Bool = true) {
        let b = section &* SIMD3(repeating: 16)
        guard b.x >= 0, b.y >= 0, b.z >= 0, b.x < w.dims.x, b.y < w.dims.y, b.z < w.dims.z else { return }
        for y in b.y..<min(b.y+16,w.dims.y) { for z in b.z..<min(b.z+16,w.dims.z) { for x in b.x..<min(b.x+16,w.dims.x) {
            let id = w.get(x,y,z), shape = w.shapeOf(id)
            if shape == .cross {
                var k = faces.face(w.state(id),4); k.transparent = true
                let a = SIMD3<Float>(Float(x),Float(y),Float(z))
                let (color,code) = BlockShading.flat(w,k,SIMD3(x,y,z)), col = Quad4(color,code)
                emit(&m,[a,a+SIMD3(1,0,1),a+SIMD3(1,1,1),a+SIMD3(0,1,0)],k,true,true,nil,.zero,col)
                emit(&m,[a+SIMD3(1,0,0),a+SIMD3(0,0,1),a+SIMD3(0,1,1),a+SIMD3(1,1,0)],k,true,true,nil,.zero,col)
            } else if shape == .slab {
                let st = w.state(id), a = SIMD3<Float>(Float(x),Float(y)+(st.contains("type=top") ? 0.5 : 0),Float(z)), b = a+SIMD3(1,0.5,1)
                let corners: [[SIMD3<Float>]] = [
                    [SIMD3(a.x,b.y,a.z),SIMD3(a.x,b.y,b.z),SIMD3(b.x,b.y,b.z),SIMD3(b.x,b.y,a.z)],
                    [a,SIMD3(b.x,a.y,a.z),SIMD3(b.x,a.y,b.z),SIMD3(a.x,a.y,b.z)],
                    [a,SIMD3(a.x,b.y,a.z),SIMD3(b.x,b.y,a.z),SIMD3(b.x,a.y,a.z)],
                    [SIMD3(b.x,a.y,b.z),b,SIMD3(a.x,b.y,b.z),SIMD3(a.x,a.y,b.z)],
                    [SIMD3(a.x,a.y,b.z),SIMD3(a.x,b.y,b.z),SIMD3(a.x,b.y,a.z),a],
                    [SIMD3(b.x,a.y,a.z),SIMD3(b.x,b.y,a.z),b,SIMD3(b.x,a.y,b.z)]]
                for (i,dir) in [3,2,4,5,0,1].enumerated() {
                    let key = faces.face(st,dir), c = corners[i]
                    let col = BlockShading.quad(w,key,SIMD3(x,y,z),dir,c[0],c[1],c[2],c[3])
                    emit(&m,c,key,true,true,nil,.zero,col)
                }
            } else if shape == .model {
                let st = w.movingShown[w.index(x,y,z)] ?? w.state(id), models = faces as? any IModelSource
                BlockModelMesher.emit(&m,w,x,y,z,st,models?.model(st),models)
            }
        } } }
        if includeFluids { FluidMesher.build(w,section,faces,&m) }
    }
    /// M1's renderer has no fluid/transparent pipeline. Explicit faces opt into M3.
    public static func buildSpecials(_ w: WorldModel, _ section: SIMD3<Int>, _ m: inout MeshData) {
        var flat = w; flat.light = nil; flat.tints = nil
        buildSpecials(flat,section,FlatFaceSource(),&m,includeFluids: false)
    }
    static func uv(_ dir: Int, _ p: SIMD3<Float>, _ k: FaceKey) -> SIMD3<Float> {
        var u: Float, v: Float
        switch dir {
        case 0: u = p.z; v = p.y
        case 1: u = -p.z; v = p.y
        case 2: u = p.x; v = p.z
        case 3: u = p.x; v = -p.z
        case 4: u = -p.x; v = p.y
        default: u = p.x; v = p.y
        }
        if k.uvMap & 1 != 0 { swap(&u,&v) }
        if k.uvMap & 2 != 0 { u = -u }; if k.uvMap & 4 != 0 { v = -v }
        return SIMD3(u,v,Float(k.layer >= 0 && k.random != 0 ? k.layer+4096*Int(k.random) : k.layer))
    }
    static func emit(_ m: inout MeshData, _ corners: [SIMD3<Float>], _ k: FaceKey, _ positive: Bool, _ doubleSided: Bool, _ dir: Int? = nil, _ b: SIMD3<Int> = .zero, _ col: Quad4? = nil, _ flip: Bool = false) {
        let s = m.verts.count
        m.verts.append(contentsOf: corners)
        if let dir { let base = SIMD3<Float>(Float(b.x),Float(b.y),Float(b.z)); m.uvs.append(contentsOf: corners.map { uv(dir,$0-base,k) }) }
        else { m.uvs.append(contentsOf: [SIMD3(0,0,Float(k.layer)),SIMD3(1,0,Float(k.layer)),SIMD3(1,1,Float(k.layer)),SIMD3(0,1,Float(k.layer))]) }
        m.addColors(col ?? Quad4(k.color))
        let front = flip ? (positive ? [0,1,3,1,2,3] : [0,3,1,1,3,2]) : (positive ? [0,1,2,0,2,3] : [0,2,1,0,3,2])
        var indices = front.map { $0+s }
        if doubleSided { indices.append(contentsOf: [s,s+2,s+1,s,s+3,s+2]) }
        if k.transparent { m.transparent.append(contentsOf: indices) } else { m.opaque.append(contentsOf: indices) }
    }
}

/// FNV-1a 64 over sorted quad rows. Vertex order, UV bits (including signed zero),
/// RGBA, light, pass and local triangle indices are retained. Sorting removes
/// quad/section scheduling order; exact(_:) additionally checks raw emission order.
/// No Unity conversion.
public enum MeshHash {
    /// quest-app/Tests~/MeshTests.cs at 281c614: exact emission order and bits,
    /// including the original offset basis (which differs from canonical's).
    public static func exact(_ m: MeshData) -> String {
        var h: UInt64 = 1469598103934665603
        func add(_ value: UInt32) {
            for i in 0..<4 { h = (h ^ UInt64((value >> (8*i)) & 255)) &* 1099511628211 }
        }
        add(UInt32(m.verts.count))
        for v in m.verts { add(v.x.bitPattern); add(v.y.bitPattern); add(v.z.bitPattern) }
        for v in m.uvs { add(v.x.bitPattern); add(v.y.bitPattern); add(v.z.bitPattern) }
        for c in m.colors { add(UInt32(c.r) | UInt32(c.g)<<8 | UInt32(c.b)<<16 | UInt32(c.a)<<24) }
        for indices in [m.opaque,m.transparent,m.waterBack] { add(UInt32(indices.count)); for i in indices { add(UInt32(i)) } }
        add(UInt32(m.light.count)); for l in m.light { add(UInt32(l)) }
        let s = String(h,radix: 16); return String(repeating: "0",count: 16-s.count)+s
    }
    public static func canonical(_ mesh: MeshData) -> String { canonical([mesh]) }
    public static func canonical(_ meshes: [MeshData]) -> String {
        var rows: [String] = []
        for m in meshes {
            var triangles: [Int: [(Int,[Int])]] = [:]
            for (pass,indices) in [m.opaque,m.transparent,m.waterBack].enumerated() {
                for i in stride(from: 0,to: indices.count,by: 3) where i+2 < indices.count {
                    let q = indices[i]/4
                    triangles[q,default: []].append((pass,[indices[i]%4,indices[i+1]%4,indices[i+2]%4]))
                }
            }
            for q in 0..<(m.verts.count/4) {
                var fields: [String] = []
                for j in 0..<4 {
                    let i = q*4+j, p = m.verts[i], uv = m.uvs[i], c = m.colors[i]
                    fields.append(contentsOf: [p.x,p.y,p.z,uv.x,uv.y,uv.z].map { String($0.bitPattern) })
                    fields.append(contentsOf: [c.r,c.g,c.b,c.a,i < m.light.count ? m.light[i] : 240].map(String.init))
                }
                for (pass,tri) in triangles[q] ?? [] { fields.append(String(pass)); fields.append(contentsOf: tri.map(String.init)) }
                rows.append(fields.joined(separator: ","))
            }
        }
        var h: UInt64 = 14695981039346656037
        for row in rows.sorted() { for b in (row+"\n").utf8 { h = (h ^ UInt64(b)) &* 1099511628211 } }
        let s = String(h,radix: 16); return String(repeating: "0",count: 16-s.count)+s
    }
}
