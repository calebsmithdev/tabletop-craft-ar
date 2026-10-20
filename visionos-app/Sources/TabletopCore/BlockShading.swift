// Port of quest-app/Assets/Scripts/World/BlockShading.cs at f7d4a0f.
// Immutable per-world noon lightmap. No shared mutable settings or live M7 environment.
public struct Quad4: Sendable, Equatable {
    public var c0, c1, c2, c3: Color32
    public var l0, l1, l2, l3: UInt8
    public init(_ color: Color32 = Color32(0,0,0,0), _ light: UInt8 = 240) {
        c0 = color; c1 = color; c2 = color; c3 = color
        l0 = light; l1 = light; l2 = light; l3 = light
    }
    public subscript(_ i: Int) -> Color32 {
        get { i == 0 ? c0 : i == 1 ? c1 : i == 2 ? c2 : c3 }
        set { if i == 0 { c0 = newValue } else if i == 1 { c1 = newValue } else if i == 2 { c2 = newValue } else { c3 = newValue } }
    }
    public func l(_ i: Int) -> UInt8 { i == 0 ? l0 : i == 1 ? l1 : i == 2 ? l2 : l3 }
    mutating func setLight(_ i: Int, _ value: UInt8) {
        if i == 0 { l0 = value } else if i == 1 { l1 = value } else if i == 2 { l2 = value } else { l3 = value }
    }
    public func same(_ i: Int, _ j: Int) -> Bool { self[i] == self[j] && l(i) == l(j) }
}

public struct BlockShading: Sendable {
    public let brightness, minLight: Float
    public let smoothLighting: Bool
    private let referenceFloor: Float
    private let lm: [SIMD3<Float>]
    private static let dirs = [SIMD3(-1,0,0),SIMD3(1,0,0),SIMD3(0,-1,0),SIMD3(0,1,0),SIMD3(0,0,-1),SIMD3(0,0,1)]
    public init(brightness: Float = 1, minLight: Float = 0.2, smoothLighting: Bool = true) {
        let brightness = max(0,min(1,brightness)), minLight = min(minLight,1)
        self.brightness = brightness; self.minLight = minLight; self.smoothLighting = smoothLighting
        let floor = Self.raw(.noon,0,0,brightness).y
        referenceFloor = floor
        lm = (0..<256).map { Self.rescale(Self.raw(.noon,$0 >> 4,$0 & 15,brightness),minLight,floor) }
    }
    public static func curve(_ level: Float) -> Float { level/(4-3*level) }
    private static func raw(_ env: LightEnv, _ sky: Int, _ block: Int, _ brightness: Float) -> SIMD3<Float> {
        let bl = Float(block)/15, sl = Float(sky)/15
        let bb = curve(bl)*env.blockFactor, sb = curve(sl)*env.skyFactor
        let mix: Float = 0.9*(2*bl-1)*(2*bl-1)
        var c = SIMD3<Float>.zero
        for i in 0..<3 {
            let tint = env.blockTint[i]+(1-env.blockTint[i])*max(0,min(1,mix))
            c[i] = max(0,min(1,env.ambient[i]+env.skyColor[i]*sb+tint*bb))
        }
        let top = max(c.x,max(c.y,c.z))
        if top > 0 {
            let inv = 1-top, scaled = 1-inv*inv*inv*inv, k = scaled/top
            for i in 0..<3 { c[i] = c[i]+(c[i]*k-c[i])*brightness }
        }
        return c
    }
    private static func rescale(_ c: SIMD3<Float>, _ minLight: Float, _ floor: Float) -> SIMD3<Float> {
        if minLight < 0 || floor >= 1 { return c }
        let k = (1-minLight)/(1-floor)
        return SIMD3(minLight+(c.x-floor)*k,minLight+(c.y-floor)*k,minLight+(c.z-floor)*k)
    }
    public func rawLightmap(_ env: LightEnv, _ sky: Int, _ block: Int) -> SIMD3<Float> { Self.raw(env,sky,block,brightness) }
    public func lightmapFor(_ env: LightEnv, _ sky: Int, _ block: Int) -> SIMD3<Float> { Self.rescale(rawLightmap(env,sky,block),minLight,referenceFloor) }
    public func lightmap(_ sky: Float, _ block: Float) -> SIMD3<Float> {
        let s = max(0,min(15,sky)), b = max(0,min(15,block))
        let s0 = Int(s), b0 = Int(b), s1 = min(s0+1,15), b1 = min(b0+1,15)
        let fs = s-Float(s0), fb = b-Float(b0)
        let w00 = (1-fs)*(1-fb), w01 = (1-fs)*fb, w10 = fs*(1-fb), w11 = fs*fb
        return lm[s0*16+b0]*w00 + lm[s0*16+b1]*w01 + lm[s1*16+b0]*w10 + lm[s1*16+b1]*w11
    }
    public static func aoOccluder(_ s: BlockShape) -> Bool { s == .cube || s == .transparentCube }
    public static func permeable(_ s: BlockShape) -> Bool { s != .cube }
    public static func tint(_ w: WorldModel, _ key: FaceKey, _ x: Int, _ y: Int, _ z: Int) -> Color32 {
        guard key.tint != .none, let tints = w.tints else { return key.color }
        let c = tints.tint(key.tint,x,y,z)
        return c < 0 ? key.color : Color32(UInt8((c >> 16)&255),UInt8((c >> 8)&255),UInt8(c&255),key.color.a)
    }
    private struct Cell {
        var sky: Int, block: Int
        var inside: Bool, occluder: Bool, opaque: Bool
    }
    private static func cell(_ w: WorldModel, _ p: SIMD3<Int>) -> Cell {
        guard w.inBounds(p.x,p.y,p.z) else { return Cell(sky: 15,block: 0,inside: false,occluder: false,opaque: false) }
        let i = w.index(p.x,p.y,p.z)
        guard let light = w.light, i < light.count, i < w.grid.count else { return Cell(sky: 15,block: 0,inside: true,occluder: false,opaque: false) }
        let s = w.shapeOf(w.grid[i]), v = light[i]
        return Cell(sky: Int(v >> 4),block: Int(v & 15),inside: true,occluder: aoOccluder(s),opaque: !permeable(s))
    }
    private static func lit(_ w: WorldModel, _ tint: Color32, _ sky: Int, _ block: Int) -> Quad4 {
        Quad4(shade(tint,w.shading.lightmap(Float(sky),Float(block)),1),LightCode.of(Float(sky),Float(block)))
    }
    public static func faceCorners(_ w: WorldModel, _ key: FaceKey, _ x: Int, _ y: Int, _ z: Int, _ dir: Int, cubic: Bool = true, floor: Int = 0) -> Quad4 {
        let tint = tint(w,key,x,y,z)
        guard w.light != nil else { return Quad4(tint) }
        if key.shade == BakedModel.shadeFullBright { return Quad4(shade(tint,w.shading.lightmap(15,15),1),LightCode.fullBright) }
        let n = dirs[dir], p = SIMD3(x,y,z), f = cubic ? p &+ n : p
        var c = cell(w,f)
        if !c.inside { return lit(w,tint,15,floor) }
        if key.shade == BakedModel.shadeFlat { return lit(w,tint,max(c.sky,floor),max(c.block,floor)) }
        if !cubic {
            let front = cell(w,p &+ n)
            if front.inside && !front.opaque { c.sky = front.sky; c.block = front.block }
        }
        if !w.shading.smoothLighting { return lit(w,tint,max(c.sky,floor),max(c.block,floor)) }
        let axis = dir >> 1, ua = (axis+1)%3, va = (axis+2)%3
        var u = SIMD3<Int>.zero, v = SIMD3<Int>.zero; u[ua] = 1; v[va] = 1
        let cAo: Float = c.occluder ? 0.2 : 1
        var q = Quad4()
        for corner in 0..<4 {
            let su = corner == 1 || corner == 2 ? 1 : -1, sv = corner >= 2 ? 1 : -1
            let ap = f &+ (u &* SIMD3(repeating: su)), bp = f &+ (v &* SIMD3(repeating: sv))
            let a = cell(w,ap), b = cell(w,bp)
            var k = a
            if !cell(w,ap &+ n).opaque || !cell(w,bp &+ n).opaque { k = cell(w,ap &+ (v &* SIMD3(repeating: sv))) }
            let aAo: Float = a.occluder ? 0.2 : 1, bAo: Float = b.occluder ? 0.2 : 1, kAo: Float = k.occluder ? 0.2 : 1
            let ao = (aAo+bAo+kAo+cAo)*0.25
            let (s,bl) = smoothBlend(a.sky,a.block,b.sky,b.block,k.sky,k.block,c.sky,c.block)
            let sky = max(s,Float(floor)), block = max(bl,Float(floor))
            q[corner] = shade(tint,w.shading.lightmap(sky,block),ao); q.setLight(corner,LightCode.of(sky,block))
        }
        return q
    }
    public static func quad(_ w: WorldModel, _ key: FaceKey, _ b: SIMD3<Int>, _ dir: Int, _ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, floor: Int = 0) -> Quad4 {
        let axis = dir >> 1, ua = (axis+1)%3, va = (axis+2)%3, plane = p0[axis]-Float(b[axis])
        let cubic = dir & 1 == 1 ? plane >= 0.999 : plane <= 0.001
        let c = faceCorners(w,key,b.x,b.y,b.z,dir,cubic: cubic,floor: floor)
        if w.light == nil { return c }
        var q = Quad4()
        for (i,p) in [p0,p1,p2,p3].enumerated() {
            let u = p[ua]-Float(b[ua]), v = p[va]-Float(b[va])
            q[i] = bilerp(c,u,v); q.setLight(i,LightCode.bilerp(c,u,v))
        }
        return q
    }
    public static func flat(_ w: WorldModel, _ key: FaceKey, _ b: SIMD3<Int>, floor: Int = 0) -> (Color32,UInt8) {
        let tint = tint(w,key,b.x,b.y,b.z)
        guard w.light != nil else { return (tint,LightCode.openSky) }
        if key.shade == BakedModel.shadeFullBright { return (shade(tint,w.shading.lightmap(15,15),1),LightCode.fullBright) }
        let c = cell(w,b), sky = max(c.sky,floor), block = max(c.block,floor)
        return (shade(tint,w.shading.lightmap(Float(sky),Float(block)),1),LightCode.of(Float(sky),Float(block)))
    }
    public static func model(_ w: WorldModel, _ x: Int, _ y: Int, _ z: Int, _ q: BakedQuad, _ shade: UInt8 = BakedModel.shadeSmooth) -> Quad4 {
        var key = FaceKey(color: q.color); key.tint = q.tint; key.shade = shade
        let b = SIMD3(x,y,z)
        if w.light == nil && (q.tint == .none || w.tints == nil) { return Quad4(q.color) }
        if q.dir < 0 { let (c,l) = flat(w,key,b,floor: Int(q.emission)); return Quad4(c,l) }
        let o = SIMD3<Float>(Float(x),Float(y),Float(z))
        return quad(w,key,b,Int(q.dir),o+q.p0,o+q.p1,o+q.p2,o+q.p3,floor: Int(q.emission))
    }
    public static func fluid(_ w: WorldModel, _ tint: Color32, _ x: Int, _ y: Int, _ z: Int, _ dir: Int) -> (Color32,UInt8) {
        guard w.light != nil else { return (tint,LightCode.openSky) }
        let p = SIMD3(x,y,z), n = p &+ dirs[dir]
        if !w.inBounds(n.x,n.y,n.z) { return (shade(tint,w.shading.lightmap(15,0),1),LightCode.openSky) }
        let c = cell(w,p), above = cell(w,p &+ SIMD3(0,1,0)), s = max(c.sky,above.sky), b = max(c.block,above.block)
        return (shade(tint,w.shading.lightmap(Float(s),Float(b)),1),LightCode.of(Float(s),Float(b)))
    }
    public static func smoothBlend(_ aS: Int, _ aB: Int, _ bS: Int, _ bB: Int, _ cS: Int, _ cB: Int, _ dS: Int, _ dB: Int) -> (Float,Float) {
        var aS = aS, aB = aB, bS = bS, bB = bB, cS = cS, cB = cB
        if dS > 2 || dB > 2 {
            if aS == 0 && aB == 0 { aS = dS; aB = dB } else if aS == 0 { aS = dS }
            if bS == 0 && bB == 0 { bS = dS; bB = dB } else if bS == 0 { bS = dS }
            if cS == 0 && cB == 0 { cS = dS; cB = dB } else if cS == 0 { cS = dS }
        }
        return (Float(aS+bS+cS+dS)*0.25,Float(aB+bB+cB+dB)*0.25)
    }
    private static func toByte(_ v: Float) -> UInt8 { UInt8(max(0,min(255,Int(v+0.5)))) }
    private static func shade(_ tint: Color32, _ light: SIMD3<Float>, _ ao: Float) -> Color32 {
        Color32(toByte(Float(tint.r)*light.x*ao),toByte(Float(tint.g)*light.y*ao),toByte(Float(tint.b)*light.z*ao),tint.a)
    }
    private static func bilerp(_ c: Quad4, _ fu: Float, _ fv: Float) -> Color32 {
        let u = max(0,min(1,fu)), v = max(0,min(1,fv)), w0 = (1-u)*(1-v), w1 = u*(1-v), w2 = u*v, w3 = (1-u)*v
        func channel(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt8 { toByte(Float(a)*w0+Float(b)*w1+Float(c)*w2+Float(d)*w3) }
        return Color32(channel(c.c0.r,c.c1.r,c.c2.r,c.c3.r),channel(c.c0.g,c.c1.g,c.c2.g,c.c3.g),channel(c.c0.b,c.c1.b,c.c2.b,c.c3.b),c.c0.a)
    }
}
