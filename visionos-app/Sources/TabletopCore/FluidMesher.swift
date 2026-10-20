// Port of quest-app/Assets/Scripts/World/FluidMesher.cs at f7d4a0f.
// Scratch is local to each build; geometry stays in the right-handed Minecraft frame.
import Foundation

public enum FluidKind: UInt8, Sendable { case none, water, lava }
public enum FluidRules {
    public static let waterState = "minecraft:water", lavaState = "minecraft:lava"
    public static let waterFlowState = "minecraft:water[tabletop=flow]", lavaFlowState = "minecraft:lava[tabletop=flow]", overlayState = "minecraft:water[tabletop=overlay]"
    public static let quadTable: UInt8 = 64
    public static func info(_ state: String) -> UInt8 {
        let p = BlockRules.path(state)
        if p == "water" || p == "lava" {
            let level = intProp(state,"level"), amount = level <= 0 || level >= 8 ? 8 : 8-level
            return (p == "water" ? FluidKind.water.rawValue : FluidKind.lava.rawValue) | UInt8(amount << 2)
        }
        if ["kelp","kelp_plant","seagrass","tall_seagrass","bubble_column"].contains(p) || state.contains("waterlogged=true") { return 1 | (8 << 2) }
        return 0
    }
    public static func kind(_ info: UInt8) -> FluidKind { FluidKind(rawValue: info & 3) ?? .none }
    public static func kind(_ state: String) -> FluidKind { kind(info(state)) }
    public static func amount(_ info: UInt8) -> Int { Int(info >> 2) }
    public static func height(_ info: UInt8) -> Float { Float(info >> 2)/9 }
    public static func faceState(_ state: String) -> String? {
        let k = kind(state); return k == .water ? waterState : k == .lava ? lavaState : nil
    }
    public static func intProp(_ state: String, _ key: String) -> Int {
        guard let open = state.firstIndex(of: "[") else { return 0 }
        var start = open
        while let r = state.range(of: key+"=",range: start..<state.endIndex) {
            if r.lowerBound > state.startIndex && ["[",","].contains(state[state.index(before: r.lowerBound)]) {
                var v = 0
                for c in state[r.upperBound...].utf8 { if c < 48 || c > 57 { break }; v = v &* 10 &+ Int(c-48) }
                return v
            }
            start = state.index(after: r.lowerBound)
        }
        return 0
    }
    public static func fullFaces(_ state: String, _ shape: BlockShape) -> UInt8 {
        if shape == .cube { return 0x3F }
        let p = BlockRules.path(state), top = state.contains("type=top") || state.contains("half=top")
        if shape == .slab || p.hasSuffix("_slab") { return state.contains("type=double") ? 0x3F : UInt8(top ? 1 << 3 : 1 << 2) }
        if p.hasSuffix("_stairs") {
            var b = top ? 1 << 3 : 1 << 2
            if state.contains("shape=straight") {
                if state.contains("facing=west") { b |= 1 << 0 } else if state.contains("facing=east") { b |= 1 << 1 }
                else if state.contains("facing=north") { b |= 1 << 4 } else if state.contains("facing=south") { b |= 1 << 5 }
            }
            return UInt8(b)
        }
        return 0
    }
}

public enum FluidMesher {
    private static let s = 16, p = 18
    private static let dirs = [SIMD3(-1,0,0),SIMD3(1,0,0),SIMD3(0,-1,0),SIMD3(0,1,0),SIMD3(0,0,-1),SIMD3(0,0,1)]
    private static func pad(_ x: Int, _ y: Int, _ z: Int) -> Int { ((y+1)*p+z+1)*p+x+1 }
    private static func cell(_ x: Int, _ y: Int, _ z: Int) -> Int { ((y*s+z)*s+x)*4 }
    public static func waterColor(_ w: WorldModel, _ x: Int, _ y: Int, _ z: Int, _ atlasTint: Color32) -> Color32 {
        var key = FaceKey(color: atlasTint); key.tint = .water; return BlockShading.tint(w,key,x,y,z)
    }
    public static func build(_ w: WorldModel, _ section: SIMD3<Int>, _ faces: any IFaceSource, _ m: inout MeshData) {
        var pass = Pass(); pass.build(w,section,faces,&m)
    }
    private struct Pass {
        var fluid = [UInt8](repeating: 0,count: p*p*p), full = [UInt8](repeating: 0,count: p*p*p), flags = [UInt8](repeating: 0,count: p*p*p)
        var corners = [Float](repeating: 0,count: s*s*s*4)
        var keys = [FaceKey](repeating: FaceKey(),count: 16)
        mutating func build(_ w: WorldModel, _ section: SIMD3<Int>, _ faces: any IFaceSource, _ m: inout MeshData) {
            let b0 = section &* SIMD3(repeating: s)
            let size = SIMD3(min(s,w.dims.x-b0.x),min(s,w.dims.y-b0.y),min(s,w.dims.z-b0.z))
            guard b0.x >= 0, b0.y >= 0, b0.z >= 0, size.x > 0, size.y > 0, size.z > 0 else { return }
            let palette = w.palette.enumerated().map { id,state -> (UInt8,UInt8,UInt8) in
                let shape = w.shapeOf(UInt16(id))
                let flags: UInt8 = 1 | (shape != .air && shape != .cross && shape != .fluid ? 2 : 0) | (shape == .transparentCube ? 4 : 0)
                return (FluidRules.info(state),FluidRules.fullFaces(state,shape),flags)
            }
            var kinds = 0
            for y in -1...s { for z in -1...s { for x in -1...s {
                let id = w.get(b0.x+x,b0.y+y,b0.z+z), i = pad(x,y,z)
                if id != .max && Int(id) < palette.count {
                    let a = palette[Int(id)]; fluid[i] = a.0; full[i] = a.1; flags[i] = a.2
                    if x >= 0 && x < size.x && y >= 0 && y < size.y && z >= 0 && z < size.z && a.0 & 3 != 0 && a.1 != 0x3F { kinds |= 1 << Int(a.0 & 3) }
                }
            } } }
            if kinds == 0 { return }
            for k in 1...2 where kinds & (1 << k) != 0 {
                let water = k == 1, st = water ? FluidRules.waterState : FluidRules.lavaState
                for d in 0..<8 {
                    var key = d < 6 ? faces.face(st,d) : d == 6 ? faces.face(water ? FluidRules.waterFlowState : FluidRules.lavaFlowState,4) : water ? faces.face(FluidRules.overlayState,4) : FaceKey()
                    if water { key.transparent = true }; keys[(k-1)*8+d] = key
                }
            }
            makeCorners(size)
            var mask = [FaceKey](repeating: FaceKey(),count: s*s), maskH = [Float](repeating: 0,count: s*s), has = [Bool](repeating: false,count: s*s)
            for dir in 0..<6 {
                let axis = dir/2, ua = (axis+1)%3, va = (axis+2)%3, selfBit = UInt8(1 << dir), nbBit = UInt8(1 << (dir^1)), n = dirs[dir]
                for d in 0..<size[axis] {
                    for v in 0..<size[va] { for u in 0..<size[ua] {
                        let k = u+v*s; has[k] = false
                        var pos = SIMD3<Int>.zero; pos[axis] = d; pos[ua] = u; pos[va] = v
                        let x = pos.x, y = pos.y, z = pos.z, i = pad(x,y,z), kind = Int(fluid[i]&3)
                        if kind == 0 || full[i] == 0x3F || full[i]&selfBit != 0 { continue }
                        let ni = pad(x+n.x,y+n.y,z+n.z)
                        if Int(fluid[ni]&3) == kind { continue }
                        let nbFull = full[ni]&nbBit != 0, c = cell(x,y,z)
                        let nw = corners[c], sw = corners[c+1], se = corners[c+2], ne = corners[c+3]
                        if dir == 3 {
                            if nbFull && nw >= 1 && sw >= 1 && se >= 1 && ne >= 1 { continue }
                            let (fx,fz) = flow(x,y,z,kind)
                            if fx != 0 || fz != 0 {
                                let key = key(w,kind,6,dir,b0 &+ pos)
                                topFlow(&m,b0,x,z,y,nw,sw,se,ne,fx,fz,key); continue
                            }
                            let key = key(w,kind,dir,dir,b0 &+ pos)
                            if nw == sw && sw == se && se == ne { mask[k] = key; maskH[k] = nw; has[k] = true }
                            else { top(&m,b0,Float(x),Float(x+1),Float(z),Float(z+1),Float(y),nw,sw,se,ne,key) }
                            continue
                        }
                        if nbFull { continue }
                        if dir == 2 { mask[k] = key(w,kind,dir,dir,b0 &+ pos); maskH[k] = 0; has[k] = true; continue }
                        let key = key(w,kind,kind == 1 && flags[ni]&4 != 0 ? 7 : 6,dir,b0 &+ pos)
                        let h0: Float, h1: Float
                        if dir == 0 { h0 = nw; h1 = sw } else if dir == 1 { h0 = ne; h1 = se } else if dir == 4 { h0 = nw; h1 = ne } else { h0 = sw; h1 = se }
                        if h0 == h1 { mask[k] = key; maskH[k] = h0; has[k] = true }
                        else if axis == 0 { side(&m,b0,dir,Float(x+(dir&1)),Float(z),Float(z+1),Float(y),Float(y)+h0,Float(y)+h1,key) }
                        else { side(&m,b0,dir,Float(z+(dir&1)),Float(x),Float(x+1),Float(y),Float(y)+h0,Float(y)+h1,key) }
                    } }
                    for v in 0..<size[va] {
                        var u = 0
                        while u < size[ua] {
                            let k = u+v*s
                            if !has[k] { u += 1; continue }
                            let key = mask[k], h = maskH[k]
                            var width = 1
                            while u+width < size[ua] && has[k+width] && maskH[k+width] == h && mask[k+width] == key { width += 1 }
                            var height = 1, ok = true
                            while v+height < size[va] && ok {
                                for i in 0..<width {
                                    let kk = k+i+height*s
                                    if !has[kk] || maskH[kk] != h || mask[kk] != key { ok = false; break }
                                }
                                if ok { height += 1 }
                            }
                            if dir == 2 { bottom(&m,b0,Float(v),Float(v+height),Float(u),Float(u+width),Float(d),key) }
                            else if dir == 3 { top(&m,b0,Float(v),Float(v+height),Float(u),Float(u+width),Float(d),h,h,h,h,key) }
                            else if axis == 0 { side(&m,b0,dir,Float(d+(dir&1)),Float(v),Float(v+height),Float(u),Float(u+width-1)+h,Float(u+width-1)+h,key) }
                            else { side(&m,b0,dir,Float(d+(dir&1)),Float(u),Float(u+width),Float(v),Float(v+height-1)+h,Float(v+height-1)+h,key) }
                            for j in 0..<height { for i in 0..<width { has[k+i+j*s] = false } }; u += width
                        }
                    }
                }
            }
        }
        func key(_ w: WorldModel, _ kind: Int, _ slot: Int, _ dir: Int, _ pos: SIMD3<Int>) -> FaceKey {
            var key = keys[(kind-1)*8+slot]
            if kind == 1 { key.color = waterColor(w,pos.x,pos.y,pos.z,key.color) }
            (key.color,key.light) = BlockShading.fluid(w,key.color,pos.x,pos.y,pos.z,dir)
            return key
        }
        mutating func makeCorners(_ size: SIMD3<Int>) {
            for y in 0..<size.y { for z in 0..<size.z { for x in 0..<size.x {
                let i = pad(x,y,z), kind = Int(fluid[i]&3)
                if kind == 0 { continue }
                let c = cell(x,y,z)
                if Int(fluid[pad(x,y+1,z)]&3) == kind { for j in 0..<4 { corners[c+j] = 1 }; continue }
                let cur = FluidRules.height(fluid[i])
                let hn = h(x,y,z-1,kind), hs = h(x,y,z+1,kind), he = h(x+1,y,z,kind), hw = h(x-1,y,z,kind)
                corners[c] = quantize(avg(cur,hn,hw,x-1,y,z-1,kind))
                corners[c+1] = quantize(avg(cur,hs,hw,x-1,y,z+1,kind))
                corners[c+2] = quantize(avg(cur,hs,he,x+1,y,z+1,kind))
                corners[c+3] = quantize(avg(cur,hn,he,x+1,y,z-1,kind))
            } } }
        }
        func h(_ x: Int, _ y: Int, _ z: Int, _ kind: Int) -> Float {
            let i = pad(x,y,z)
            if Int(fluid[i]&3) == kind { return Int(fluid[pad(x,y+1,z)]&3) == kind ? 1 : FluidRules.height(fluid[i]) }
            return flags[i]&1 == 0 || flags[i]&2 != 0 ? -1 : 0
        }
        func avg(_ cur: Float, _ a: Float, _ b: Float, _ dx: Int, _ dy: Int, _ dz: Int, _ kind: Int) -> Float {
            if a >= 1 || b >= 1 { return 1 }
            var sum: Float = 0, wt: Float = 0
            if a > 0 || b > 0 {
                let diag = h(dx,dy,dz,kind)
                if diag >= 1 { return 1 }; add(&sum,&wt,diag)
            }
            add(&sum,&wt,cur); add(&sum,&wt,b); add(&sum,&wt,a)
            return sum/wt
        }
        func flow(_ x: Int, _ y: Int, _ z: Int, _ kind: Int) -> (Float,Float) {
            var fx: Float = 0, fz: Float = 0
            let own = FluidRules.height(fluid[pad(x,y,z)])
            pull(x,y,z-1,kind,own,0,-1,&fx,&fz); pull(x+1,y,z,kind,own,1,0,&fx,&fz)
            pull(x,y,z+1,kind,own,0,1,&fx,&fz); pull(x-1,y,z,kind,own,-1,0,&fx,&fz)
            return (fx,fz)
        }
        func pull(_ x: Int, _ y: Int, _ z: Int, _ kind: Int, _ own: Float, _ sx: Float, _ sz: Float, _ fx: inout Float, _ fz: inout Float) {
            let i = pad(x,y,z), nk = Int(fluid[i]&3)
            if nk != 0 && nk != kind { return }
            let d: Float
            if nk == kind { d = own-FluidRules.height(fluid[i]) }
            else {
                if flags[i]&2 != 0 { return }
                let b = fluid[pad(x,y-1,z)]
                if Int(b&3) != kind { return }
                d = own-(FluidRules.height(b)-8/9)
            }
            fx += sx*d; fz += sz*d
        }
    }
    private static func quantize(_ h: Float) -> Float { h >= 1 ? 1 : Float((Double(h)*576).rounded(.toNearestOrEven))/576 }
    private static func add(_ sum: inout Float, _ wt: inout Float, _ h: Float) {
        if h >= 0.8 { sum += h*10; wt += 10 } else if h >= 0 { sum += h; wt += 1 }
    }
    public static func flowUvs(_ fx: Float, _ fz: Float) -> [SIMD2<Float>] {
        // UnityStubs/Mathf evaluates trig in Double, then rounds to Float. Keep
        // the angle subtraction and quarter scaling in Float, in C# order.
        let a = Float(atan2(Double(fz),Double(fx)))-Float(Double.pi)/2
        let s = Float(sin(Double(a)))*0.25, c = Float(cos(Double(a)))*0.25
        return [SIMD2(2*(0.5-c-s),-2*(0.5-c+s)),SIMD2(2*(0.5-c+s),-2*(0.5+c+s)),SIMD2(2*(0.5+c+s),-2*(0.5+c-s)),SIMD2(2*(0.5+c-s),-2*(0.5-c-s))]
    }
    public static func flowUvs(_ fx: Float, _ fz: Float, _ uv: inout [SIMD2<Float>]) { uv = flowUvs(fx,fz) }
    private static func top(_ m: inout MeshData, _ b: SIMD3<Int>, _ x0: Float, _ x1: Float, _ z0: Float, _ z1: Float, _ y: Float, _ nw: Float, _ sw: Float, _ se: Float, _ ne: Float, _ key: FaceKey) {
        quad(&m,b,3,[SIMD3(x0,y+nw,z0),SIMD3(x0,y+sw,z1),SIMD3(x1,y+se,z1),SIMD3(x1,y+ne,z0)],key)
    }
    private static func topFlow(_ m: inout MeshData, _ b: SIMD3<Int>, _ x: Int, _ z: Int, _ y: Int, _ nw: Float, _ sw: Float, _ se: Float, _ ne: Float, _ fx: Float, _ fz: Float, _ key: FaceKey) {
        let x = Float(x), y = Float(y), z = Float(z)
        quad(&m,b,[SIMD3(x,y+nw,z),SIMD3(x,y+sw,z+1),SIMD3(x+1,y+se,z+1),SIMD3(x+1,y+ne,z)],flowUvs(fx,fz),key)
    }
    private static func bottom(_ m: inout MeshData, _ b: SIMD3<Int>, _ x0: Float, _ x1: Float, _ z0: Float, _ z1: Float, _ y: Float, _ key: FaceKey) {
        quad(&m,b,2,[SIMD3(x0,y,z0),SIMD3(x1,y,z0),SIMD3(x1,y,z1),SIMD3(x0,y,z1)],key)
    }
    private static func side(_ m: inout MeshData, _ b: SIMD3<Int>, _ dir: Int, _ plane: Float, _ t0: Float, _ t1: Float, _ y: Float, _ top0: Float, _ top1: Float, _ key: FaceKey) {
        let p: [SIMD3<Float>]
        switch dir {
        case 0: p = [SIMD3(plane,y,t0),SIMD3(plane,y,t1),SIMD3(plane,top1,t1),SIMD3(plane,top0,t0)]
        case 1: p = [SIMD3(plane,y,t1),SIMD3(plane,y,t0),SIMD3(plane,top0,t0),SIMD3(plane,top1,t1)]
        case 4: p = [SIMD3(t1,y,plane),SIMD3(t0,y,plane),SIMD3(t0,top0,plane),SIMD3(t1,top1,plane)]
        default: p = [SIMD3(t0,y,plane),SIMD3(t1,y,plane),SIMD3(t1,top1,plane),SIMD3(t0,top0,plane)]
        }
        quad(&m,b,dir,p,key)
    }
    private static func uv(_ dir: Int, _ p: SIMD3<Float>) -> SIMD2<Float> {
        switch dir {
        case 0: return SIMD2(p.z,p.y)
        case 1: return SIMD2(-p.z,p.y)
        case 2: return SIMD2(p.x,p.z)
        case 3: return SIMD2(p.x,-p.z)
        case 4: return SIMD2(-p.x,p.y)
        default: return SIMD2(p.x,p.y)
        }
    }
    private static func quad(_ m: inout MeshData, _ b: SIMD3<Int>, _ dir: Int, _ p: [SIMD3<Float>], _ key: FaceKey) { quad(&m,b,p,p.map { uv(dir,$0) },key) }
    private static func quad(_ m: inout MeshData, _ b: SIMD3<Int>, _ p: [SIMD3<Float>], _ uv: [SIMD2<Float>], _ key: FaceKey) {
        let s = m.verts.count, base = SIMD3<Float>(Float(b.x),Float(b.y),Float(b.z))
        let z = Float(key.layer >= 0 && key.random != 0 ? key.layer+4096*Int(key.random) : key.layer)
        for i in 0..<4 { m.verts.append(p[i]+base); m.uvs.append(SIMD3(uv[i].x,uv[i].y,z)) }
        m.addColors(Quad4(key.color,key.light))
        let indices = [s,s+1,s+2,s,s+2,s+3]
        if key.transparent { m.transparent.append(contentsOf: indices) } else { m.opaque.append(contentsOf: indices) }
        if key.transparent {
            let b = m.verts.count
            for i in 0..<4 { m.verts.append(m.verts[s+i]); m.uvs.append(m.uvs[s+i]); m.copyColor(s+i) }
            m.waterBack.append(contentsOf: [b,b+2,b+1,b,b+3,b+2])
        }
    }
}
