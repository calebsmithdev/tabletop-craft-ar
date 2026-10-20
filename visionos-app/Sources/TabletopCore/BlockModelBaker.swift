// Port of quest-app/Assets/Scripts/World/BlockModelBaker.cs at 455a58a.
// Engine-free mesh-data port. No Z mirror or triangle reversal for Unity.
import Foundation

/// One face in Minecraft block-local coordinates; texture V points up.
/// Value semantics permit editing a local copy without changing a published snapshot.
public struct BakedQuad: Sendable, Equatable {
    public var p0, p1, p2, p3: SIMD3<Float>
    public var t0, t1, t2, t3: SIMD3<Float>
    public var color: Color32
    public var cull, dir: Int8
    public var tinted: Bool
    public var tint: TintKind
    public var translucent: Bool
    public var emission: UInt8
    public init(p0: SIMD3<Float> = .zero, p1: SIMD3<Float> = .zero, p2: SIMD3<Float> = .zero, p3: SIMD3<Float> = .zero,
                t0: SIMD3<Float> = .zero, t1: SIMD3<Float> = .zero, t2: SIMD3<Float> = .zero, t3: SIMD3<Float> = .zero,
                color: Color32 = Color32(0,0,0,0), cull: Int8 = -1, dir: Int8 = -1, tinted: Bool = false,
                tint: TintKind = .none, translucent: Bool = false, emission: UInt8 = 0) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
        self.t0 = t0; self.t1 = t1; self.t2 = t2; self.t3 = t3
        self.color = color; self.cull = cull; self.dir = dir; self.tinted = tinted
        self.tint = tint; self.translucent = translucent; self.emission = emission
    }
}

public struct BakedModel: Sendable {
    public var quads: [BakedQuad] = []
    public var fullCube = false
    public var opaque = false
    public var cubeFaces: [FaceKey]?
    public var cover = [UInt64](repeating: 0,count: 24)
    public var cullCells: [UInt64] = []
    // Array is an indirect value container. Entries are independent finished models,
    // captured BEFORE assigning variants, so variant zero never refers back to self.
    public var variants: [BakedModel]?
    public var randomTotals: [Int]?
    public var randomMultipart = false
    public var shade: UInt8 = 0
    public static let shadeSmooth: UInt8 = 0, shadeFlat: UInt8 = 1, shadeFullBright: UInt8 = 2
    public var offsetKind: UInt8 = 0
    public var maxHorizontalOffset: Float = 0.25
    public var maxVerticalOffset: Float = 0.2
    public init() {}
    public func covers(_ dir: Int, _ cells: [UInt64], _ quad: Int) -> Bool {
        let c = dir*4, q = quad*4
        return (cells[q] & ~cover[c]) == 0 && (cells[q+1] & ~cover[c+1]) == 0 &&
               (cells[q+2] & ~cover[c+2]) == 0 && (cells[q+3] & ~cover[c+3]) == 0
    }
    public func pick(_ x: Int, _ y: Int, _ z: Int) -> BakedModel {
        guard let variants else { return self }
        return variants[BlockRandom.pick(self,x,y,z)]
    }
}

/// Preparation only. Asset owners need not be Sendable.
public protocol IModelAssets {
    func readJson(_ path: String) -> JSONObject?
    func texture(_ texture: String, _ tinted: Bool, _ state: String) -> FaceKey
    func alphaClass(_ layer: Int) -> Int
}
public protocol IModelSource: Sendable {
    func model(_ state: String) -> BakedModel?
}

/// Mutable, deliberately non-Sendable builder; publish completed models as values.
public final class BlockModelBaker {
    public static let dirNames = ["west","east","down","up","north","south"]
    private static let dirVec: [SIMD3<Float>] = [SIMD3(-1,0,0),SIMD3(1,0,0),SIMD3(0,-1,0),SIMD3(0,1,0),SIMD3(0,0,-1),SIMD3(0,0,1)]
    private static let corners = [
        [0,1,0, 0,0,0, 0,0,1, 0,1,1], [1,1,1, 1,0,1, 1,0,0, 1,1,0],
        [0,0,1, 0,0,0, 1,0,0, 1,0,1], [0,1,0, 0,1,1, 1,1,1, 1,1,0],
        [1,1,0, 1,0,0, 0,0,0, 0,1,0], [0,1,1, 0,0,1, 1,0,1, 1,1,1]
    ]
    private let assets: any IModelAssets
    private var blockstates: [String: JSONObject] = [:]
    private var missingBlockstates: Set<String> = []
    private var resolved: [String: Resolved] = [:]
    private var missingModels: Set<String> = []
    private var hasBlockColor = false
    private var tintKind: TintKind = .none
    private var blockColor = Color32(0,0,0,0)
    private var emission: UInt8 = 0
    public var entityBoxes = true
    public var onlyEntityBoxes = false
    public static let maxRandomCombos = 64
    public init(_ assets: any IModelAssets) { self.assets = assets }

    fileprivate struct TexRef { var value: String?; var force = false }
    fileprivate struct Resolved {
        var textures: [String: TexRef] = [:]
        var elements: [JSONValue]?
        var ao: Bool?
    }
    private struct M3 {
        var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0, e: Float = 0, f: Float = 0, g: Float = 0, h: Float = 0, i: Float = 0
        static var identity: M3 { M3(a: 1,e: 1,i: 1) }
        static func snap(_ x: Double) -> Float { abs(x) < 1e-6 ? 0 : abs(x-1) < 1e-6 ? 1 : abs(x+1) < 1e-6 ? -1 : Float(x) }
        static func x(_ deg: Double) -> M3 { let r = deg * Double.pi / 180, co = snap(cos(r)), si = snap(sin(r)); return M3(a: 1,e: co,f: -si,h: si,i: co) }
        static func y(_ deg: Double) -> M3 { let r = deg * Double.pi / 180, co = snap(cos(r)), si = snap(sin(r)); return M3(a: co,c: si,e: 1,g: -si,i: co) }
        static func z(_ deg: Double) -> M3 { let r = deg * Double.pi / 180, co = snap(cos(r)), si = snap(sin(r)); return M3(a: co,b: -si,d: si,e: co,i: 1) }
        static func * (p: M3, q: M3) -> M3 {
            M3(a: p.a*q.a+p.b*q.d+p.c*q.g, b: p.a*q.b+p.b*q.e+p.c*q.h, c: p.a*q.c+p.b*q.f+p.c*q.i,
               d: p.d*q.a+p.e*q.d+p.f*q.g, e: p.d*q.b+p.e*q.e+p.f*q.h, f: p.d*q.c+p.e*q.f+p.f*q.i,
               g: p.g*q.a+p.h*q.d+p.i*q.g, h: p.g*q.b+p.h*q.e+p.i*q.h, i: p.g*q.c+p.h*q.f+p.i*q.i)
        }
        func mul(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(a*v.x+b*v.y+c*v.z,d*v.x+e*v.y+f*v.z,g*v.x+h*v.y+i*v.z) }
        var isIdentity: Bool { a == 1 && e == 1 && i == 1 && b == 0 && c == 0 && d == 0 && f == 0 && g == 0 && h == 0 }
        static func model(_ x: Double, _ y: Double) -> M3 { Self.y(-y) * Self.x(-x) }
    }
    private struct ElementRot {
        var on = false
        var r = M3()
        var origin = SIMD3<Float>.zero
        var scale = SIMD3<Float>(repeating: 1)
    }

    public static func props(_ state: String) -> [String: String] {
        guard let i = state.firstIndex(of: "[") else { return [:] }
        var text = String(state[state.index(after: i)...])
        while text.last == "]" { text.removeLast() }
        var result: [String: String] = [:]
        for kv in text.split(separator: ",",omittingEmptySubsequences: false) {
            if let e = kv.firstIndex(of: "="), e != kv.startIndex { result[String(kv[..<e])] = String(kv[kv.index(after: e)...]) }
        }
        return result
    }

    public func bake(_ state: String) -> BakedModel? {
        let name = BlockRules.name(state), ns = name.firstIndex(of: ":").map { String(name[..<$0]) } ?? "minecraft"
        let path = BlockRules.path(state), key = ns+":"+path
        if missingBlockstates.contains(key) { return nil }
        if blockstates[key] == nil {
            guard let bs = assets.readJson("assets/\(ns)/blockstates/\(path).json") else { missingBlockstates.insert(key); return nil }
            blockstates[key] = bs
        }
        guard let bs = blockstates[key] else { return nil }
        let p = Self.props(state)
        var slots: [Slot] = []
        if let variants = bs.o("variants") {
            var pick: JSONValue?, fallback: JSONValue?
            for (key,value) in PackJSON.members(variants) {
                if fallback == nil { fallback = value }
                if Self.variantMatches(key,p) { pick = value; break }
            }
            if let slot = Slot.of(pick ?? fallback) { slots.append(slot) }
        }
        let multipart = bs.a("multipart")
        for value in multipart ?? [] {
            if let part = value.objectValue, part["when"] == nil || Self.when(part["when"]!,p), let slot = Slot.of(part["apply"]) { slots.append(slot) }
        }
        hasBlockColor = Self.blockColor(path,p,&blockColor)
        tintKind = BiomeColors.blockTint(state).0
        var totals: [Int] = []
        for s in slots where s.entries.count > 1 && !totals.contains(s.total) { totals.append(s.total) }
        var combos = 1
        // Saturate beyond the same limit instead of allowing hostile weights to
        // overflow a host Int before the C# combination-limit fallback.
        for t in totals { if t > Self.maxRandomCombos / combos { combos = Self.maxRandomCombos+1; break }; combos *= t }
        if totals.isEmpty || combos > Self.maxRandomCombos { totals = []; combos = 1 }
        var all: [BakedModel] = []
        for c in 0..<combos {
            var digits = [Int](repeating: 0,count: totals.count), rest = c
            for i in totals.indices.reversed() { digits[i] = rest % totals[i]; rest /= totals[i] }
            var quads: [BakedQuad] = [], firstModel: Resolved?
            for s in slots {
                let a: JSONObject
                if s.entries.count == 1 || totals.isEmpty { a = s.entries[0] }
                else { a = s.pick(digits[totals.firstIndex(of: s.total)!]) }
                guard let id = a.s("model"), let r = resolve(id) else { continue }
                if firstModel == nil { firstModel = r }
                let rot = M3.model(a.d("x"),a.d("y")), uvlock = a.b("uvlock")
                for value in r.elements ?? [] { if let el = value.objectValue { bakeElement(el,r,rot,uvlock,state,&quads) } }
            }
            BlockEntityBoxes.add(self,path,p,firstModel,state,&quads)
            guard var m = finish(quads) else { return nil }
            Self.setShade(&m,Self.shadeOf(state,p,firstModel))
            all.append(m)
        }
        var m = all[0]
        if combos > 1 {
            for k in 1..<combos { for i in m.cover.indices { m.cover[i] &= all[k].cover[i] } }
            all[0].cover = m.cover
            m.variants = all; m.randomTotals = totals; m.randomMultipart = multipart != nil
        }
        BlockRandom.setOffset(&m,path)
        return m
    }

    private static func shadeOf(_ state: String, _ p: [String:String], _ first: Resolved?) -> UInt8 {
        let path = BlockRules.path(state)
        if path == "magma_block" { return BakedModel.shadeFullBright }
        if (path == "sculk_sensor" || path == "calibrated_sculk_sensor") && p["sculk_sensor_phase"] == "active" { return BakedModel.shadeFullBright }
        return first?.ao == false ? BakedModel.shadeFlat : BakedModel.shadeSmooth
    }
    private static func setShade(_ m: inout BakedModel, _ shade: UInt8) {
        m.shade = shade
        if var faces = m.cubeFaces { for d in 0..<6 { faces[d].shade = shade }; m.cubeFaces = faces }
    }
    private struct Slot {
        var entries: [JSONObject] = [], weights: [Int] = []
        var total = 0
        static func of(_ v: JSONValue?) -> Slot? {
            var s = Slot()
            if let list = v?.arrayValue { for value in list { if let d = value.objectValue { s.add(d) } } }
            else if let d = v?.objectValue { s.add(d) }
            return s.entries.isEmpty ? nil : s
        }
        mutating func add(_ d: JSONObject) {
            let w = max(1,d.i("weight",1))
            entries.append(d); weights.append(w)
            let (sum,overflow) = total.addingReportingOverflow(w)
            total = overflow ? Int.max : sum
        }
        func pick(_ r: Int) -> JSONObject {
            var r = r
            for i in entries.indices { r -= weights[i]; if r < 0 { return entries[i] } }
            return entries[entries.count-1]
        }
    }
    public func bakeModel(_ model: String, _ state: String) -> BakedModel? {
        guard let r = resolve(model), let elements = r.elements, !elements.isEmpty else { return nil }
        hasBlockColor = Self.blockColor(BlockRules.path(state),Self.props(state),&blockColor)
        tintKind = BiomeColors.blockTint(state).0
        var quads: [BakedQuad] = []
        for value in elements { if let e = value.objectValue { bakeElement(e,r,.identity,false,state,&quads) } }
        return finish(quads)
    }
    private static func variantMatches(_ key: String, _ p: [String:String]) -> Bool {
        if key.isEmpty { return true }
        for cond in key.split(separator: ",",omittingEmptySubsequences: false) {
            guard let e = cond.firstIndex(of: "=") else { continue }
            if p[String(cond[..<e])] != String(cond[cond.index(after: e)...]) { return false }
        }
        return true
    }
    private static func jsonValue(_ v: JSONValue) -> String? {
        switch v {
        case .bool(let b): b ? "true" : "false"
        case .number(let d): Int64(exactly: d.rounded(.towardZero)).map(String.init)
        case .string(let s): s
        default: nil
        }
    }
    public static func when(_ cond: JSONValue, _ p: [String:String]) -> Bool {
        guard let c = cond.objectValue else { return true }
        if let list = c.a("OR") { return list.contains { when($0,p) } }
        if let list = c.a("AND") { return list.allSatisfy { when($0,p) } }
        for (key,value) in PackJSON.members(c) {
            guard var want = jsonValue(value) else { return false }
            let neg = want.hasPrefix("!")
            if neg { want.removeFirst() }
            let any = want.split(separator: "|",omittingEmptySubsequences: false).contains { String($0) == p[key] }
            if any == neg { return false }
        }
        return true
    }
    public static func blockColor(_ path: String, _ p: [String:String], _ c: inout Color32) -> Bool {
        c = Color32(0,0,0,0)
        if path == "redstone_wire" {
            let f = Float(Int(p["power"] ?? "") ?? 0)/15
            let r = f*0.6 + (f > 0 ? Float(0.4) : Float(0.3)), g = max(0,f*f*0.7-0.5), b = max(0,f*f*0.6-0.7)
            c = Color32(UInt8(truncatingIfNeeded: Int(r*255)),UInt8(truncatingIfNeeded: Int(g*255)),UInt8(truncatingIfNeeded: Int(b*255)))
            return true
        }
        if path == "pumpkin_stem" || path == "melon_stem" {
            let age = Int(p["age"] ?? "") ?? 0
            c = Color32(UInt8(truncatingIfNeeded: age &* 32),UInt8(truncatingIfNeeded: 255 &- (age &* 8)),UInt8(truncatingIfNeeded: age &* 4))
            return true
        }
        if path == "attached_pumpkin_stem" || path == "attached_melon_stem" { c = Color32(224,199,28); return true }
        return false
    }
    private func resolve(_ model: String) -> Resolved? {
        if let done = resolved[model] { return done }
        if missingModels.contains(model) { return nil }
        var r = Resolved(), cur: String? = model
        for depth in 0..<16 {
            guard let current = cur, !current.hasPrefix("builtin/") else { break }
            var ns = "minecraft", path = current
            if let c = current.firstIndex(of: ":") { ns = String(current[..<c]); path = String(current[current.index(after: c)...]) }
            guard let mj = assets.readJson("assets/\(ns)/models/\(path).json") else {
                if depth == 0 { missingModels.insert(model); return nil }; break
            }
            for (key,value) in PackJSON.members(mj.o("textures") ?? [:]) where r.textures[key] == nil {
                if let s = value.stringValue { r.textures[key] = TexRef(value: s) }
                else if let o = value.objectValue { r.textures[key] = TexRef(value: o.s("sprite"),force: o.b("force_translucent")) }
            }
            if r.elements == nil { r.elements = mj.a("elements") }
            if r.ao == nil { r.ao = mj["ambientocclusion"]?.boolValue }
            cur = mj.s("parent")
        }
        resolved[model] = r
        return r
    }
    private static func lookup(_ r: Resolved, _ reference: String?) -> (String,Bool)? {
        var texture = reference, force = false
        for _ in 0..<16 {
            guard let s = texture, s.hasPrefix("#") else { break }
            guard let t = r.textures[String(s.dropFirst())] else { texture = nil; break }
            texture = t.value; force = force || t.force
        }
        guard let texture, !texture.hasPrefix("#") else { return nil }
        return (texture,force)
    }
    fileprivate func particleOf(_ r: Resolved?, _ state: String) -> FaceKey? {
        guard let r, let (tex,_) = Self.lookup(r,"#particle") else { return nil }
        let key = assets.texture(tex,false,state)
        return key.layer >= 0 ? key : nil
    }
    fileprivate func texture(_ texture: String, _ state: String) -> FaceKey { assets.texture(texture,false,state) }
    private static func v(_ list: [JSONValue]?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let list, list.count >= 3, let x = list[0].numberValue, let y = list[1].numberValue, let z = list[2].numberValue else { return fallback }
        return SIMD3(Float(x),Float(y),Float(z))
    }
    private func bakeElement(_ el: JSONObject, _ r: Resolved, _ rot: M3, _ uvlock: Bool, _ state: String, _ outQ: inout [BakedQuad]) {
        let from = Self.v(el.a("from"),.zero), to = Self.v(el.a("to"),SIMD3(repeating: 16))
        let er = Self.elementRotation(el.o("rotation"))
        guard let faces = el.o("faces") else { return }
        emission = UInt8(max(0,min(15,el.i("light_emission"))))
        let inverted = from.x > to.x || from.y > to.y || from.z > to.z
        for d in 0..<6 {
            guard let f = faces.o(Self.dirNames[d]) else { continue }
            var reference = f.s("texture")
            if let s = reference, !s.hasPrefix("#"), r.textures[s] != nil { reference = "#"+s }
            guard let (tex,force) = Self.lookup(r,reference) else { continue }
            var tinted = f["tintindex"] != nil && BiomeColors.tinted(state,f.i("tintindex",-1))
            var key = assets.texture(tex,tinted && !hasBlockColor,state)
            if tinted && hasBlockColor { if key.layer >= 0 { key.color = blockColor }; tinted = false }
            if inverted && key.layer >= 0 && assets.alphaClass(key.layer) == 0 { continue }
            var uv = Self.defaultUv(d,from,to)
            if let u = f.a("uv"), u.count >= 4 { for k in 0..<4 { if let x = u[k].numberValue { uv[k] = Float(x) } } }
            let cull = Self.cullIndex(f.s("cullface"))
            let translucent = force || (key.layer >= 0 && assets.alphaClass(key.layer) == 2)
            emit(from,to,d,uv,f.i("rotation"),key,tinted,translucent,cull,er,rot,uvlock,&outQ)
        }
    }
    private static func cullIndex(_ s: String?) -> Int {
        guard let s else { return -1 }
        return s == "bottom" ? 2 : dirNames.firstIndex(of: s) ?? -1
    }
    private static func elementRotation(_ r: JSONObject?) -> ElementRot {
        var e = ElementRot()
        guard let r else { return e }
        e.origin = v(r.a("origin"),SIMD3(repeating: 8))
        if let axis = r.s("axis") {
            let angle = r.d("angle")
            if abs(angle) < 1e-9 { return e }
            e.r = axis == "x" ? M3.x(angle) : axis == "y" ? M3.y(angle) : M3.z(angle)
            if r.b("rescale") {
                let s = Float(1/cos(angle * Double.pi / 180))
                e.scale = axis == "x" ? SIMD3(1,s,s) : axis == "y" ? SIMD3(s,1,s) : SIMD3(s,s,1)
            }
        } else {
            let x = r.d("x"), y = r.d("y"), z = r.d("z")
            if abs(x)+abs(y)+abs(z) < 1e-9 { return e }
            e.r = M3.z(z) * M3.y(y) * M3.x(x)
        }
        e.on = true
        return e
    }
    private static func defaultUv(_ d: Int, _ f: SIMD3<Float>, _ t: SIMD3<Float>) -> [Float] {
        switch d {
        case 0: [f.z,16-t.y,t.z,16-f.y]
        case 1: [16-t.z,16-t.y,16-f.z,16-f.y]
        case 2: [f.x,16-t.z,t.x,16-f.z]
        case 3: [f.x,f.z,t.x,t.z]
        case 4: [16-t.x,16-t.y,16-f.x,16-f.y]
        default: [f.x,16-t.y,t.x,16-f.y]
        }
    }
    private static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) }
    private static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x+a.y*b.y+a.z*b.z }
    private static func snap(_ v: SIMD3<Float>, _ minimum: Float) -> Int {
        let len = Float(sqrt(Double(dot(v,v))))
        if len < 1e-9 { return -1 }
        for d in 0..<6 where dot(v,dirVec[d])/len > minimum { return d }
        return -1
    }
    private func emit(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ d: Int, _ uv: [Float], _ faceRot: Int, _ key: FaceKey,
                      _ tinted: Bool, _ translucent: Bool, _ cull: Int, _ er: ElementRot, _ rot: M3, _ uvlock: Bool, _ outQ: inout [BakedQuad]) {
        let corners = Self.corners[d]
        var p = [SIMD3<Float>](repeating: .zero,count: 4), cull = cull
        for i in 0..<4 {
            var v = SIMD3(corners[i*3] == 1 ? to.x : from.x,corners[i*3+1] == 1 ? to.y : from.y,corners[i*3+2] == 1 ? to.z : from.z)
            if er.on { let q = er.r.mul(v-er.origin); v = SIMD3(q.x*er.scale.x,q.y*er.scale.y,q.z*er.scale.z)+er.origin }
            if !rot.isIdentity { v = rot.mul(v-SIMD3(repeating: 8))+SIMD3(repeating: 8) }
            p[i] = v
        }
        var n = Self.cross(p[1]-p[0],p[2]-p[0])
        if Self.dot(n,n) < 1e-8 { n = Self.cross(p[2]-p[0],p[3]-p[0]); if Self.dot(n,n) < 1e-8 { return } }
        let dir = Self.snap(n,0.999)
        if cull >= 0 && !rot.isIdentity { cull = Self.snap(rot.mul(Self.dirVec[cull]),0.5) }
        var t = [SIMD3<Float>](repeating: .zero,count: 4)
        for i in 0..<4 {
            let u: Float, v: Float
            if uvlock && !rot.isIdentity && dir >= 0 {
                let pp = p[i]
                switch dir {
                case 0: u = pp.z; v = 16-pp.y
                case 1: u = 16-pp.z; v = 16-pp.y
                case 2: u = pp.x; v = 16-pp.z
                case 3: u = pp.x; v = pp.z
                case 4: u = 16-pp.x; v = 16-pp.y
                default: u = pp.x; v = 16-pp.y
                }
            } else {
                let s = (i+((faceRot/90)%4+4))%4
                u = s == 0 || s == 1 ? uv[0] : uv[2]
                v = s == 0 || s == 3 ? uv[1] : uv[3]
            }
            t[i] = SIMD3(u/16,1-v/16,Float(key.layer))
        }
        let k: Float = 1/16
        outQ.append(BakedQuad(p0: p[0]*k,p1: p[1]*k,p2: p[2]*k,p3: p[3]*k,t0: t[0],t1: t[1],t2: t[2],t3: t[3],
                             color: key.color,cull: Int8(cull),dir: Int8(dir),tinted: tinted,tint: tinted ? tintKind : .none,translucent: translucent,emission: emission))
    }
    fileprivate func box(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ key: FaceKey, _ yaw: Double, _ outQ: inout [BakedQuad]) {
        let rot = M3.model(0,yaw), rightAngle = abs(yaw.truncatingRemainder(dividingBy: 90)) < 1e-6
        emission = 0
        for d in 0..<6 {
            let plane = d%2 == 0 ? from[d/2] : to[d/2]
            let cull = rightAngle && (plane == 0 || plane == 16) ? d : -1
            emit(from,to,d,Self.defaultUv(d,from,to),0,key,false,false,cull,ElementRot(),rot,false,&outQ)
        }
    }
    private static func onBoundary(_ q: BakedQuad, _ dir: Int) -> Bool {
        let axis = dir/2, plane: Float = dir%2 == 0 ? 0 : 1
        return abs(q.p0[axis]-plane) < 1e-4 && abs(q.p1[axis]-plane) < 1e-4 && abs(q.p2[axis]-plane) < 1e-4 && abs(q.p3[axis]-plane) < 1e-4
    }
    private static func bounds2(_ q: BakedQuad, _ dir: Int) -> (Float,Float,Float,Float) {
        let ua = dir/2 == 0 ? 2 : 0, va = dir/2 == 1 ? 2 : 1
        return (min(min(q.p0[ua],q.p1[ua]),min(q.p2[ua],q.p3[ua])),min(min(q.p0[va],q.p1[va]),min(q.p2[va],q.p3[va])),
                max(max(q.p0[ua],q.p1[ua]),max(q.p2[ua],q.p3[ua])),max(max(q.p0[va],q.p1[va]),max(q.p2[va],q.p3[va])))
    }
    private static func fill(_ bits: inout [UInt64], _ at: Int, _ a0: Int, _ b0: Int, _ a1: Int, _ b1: Int) {
        let loA = max(0,a0), hiA = min(16,a1), loB = max(0,b0), hiB = min(16,b1)
        guard loA < hiA, loB < hiB else { return }
        for b in loB..<hiB { for a in loA..<hiA { let i = b*16+a; bits[at+(i>>6)] |= UInt64(1) << (i&63) } }
    }
    private func isOpaque(_ q: BakedQuad) -> Bool {
        let layer = Int(q.t0.z)
        return !q.translucent && (layer >= 0 ? assets.alphaClass(layer) == 0 : q.color.a == 255)
    }
    private func finish(_ quads: [BakedQuad]) -> BakedModel? {
        // A resource pack is untrusted input. Swift's Float-to-Int conversions
        // trap, so reject a malformed model before calculating coverage masks.
        for q in quads {
            for p in [q.p0,q.p1,q.p2,q.p3] {
                for axis in 0..<3 {
                    let scaled = Double(p[axis]*16)
                    guard p[axis].isFinite,
                          Int(exactly: floor(scaled-1e-3)) != nil,
                          Int(exactly: ceil(scaled+1e-3)) != nil else { return nil }
                }
            }
            for uv in [q.t0,q.t1,q.t2,q.t3] {
                guard uv.x.isFinite, uv.y.isFinite, uv.z.isFinite,
                      Int(exactly: Double(uv.z.rounded(.towardZero))) != nil else { return nil }
            }
        }
        var m = BakedModel()
        m.quads = quads; m.cullCells = [UInt64](repeating: 0,count: quads.count*4)
        var first = [Int](repeating: -1,count: 6), second = first
        var onlyShell = true, inside = true
        for (i,q) in quads.enumerated() {
            let d = Int(q.dir), boundary = d >= 0 && Self.onBoundary(q,d)
            var (a0,b0,a1,b1): (Float,Float,Float,Float) = d >= 0 ? Self.bounds2(q,d) : (0,0,0,0)
            let whole = boundary && a0 < 1e-4 && b0 < 1e-4 && a1 > 1-Float(1e-4) && b1 > 1-Float(1e-4)
            if !(whole && q.cull == d) { onlyShell = false }
            if whole && q.cull == d && first[d] < 0 { first[d] = i }
            else if whole && q.cull == d && second[d] < 0 { second[d] = i }
            for a in 0..<3 where min(min(q.p0[a],q.p1[a]),min(q.p2[a],q.p3[a])) < -1e-4 || max(max(q.p0[a],q.p1[a]),max(q.p2[a],q.p3[a])) > 1+Float(1e-4) { inside = false }
            // C# promotes the Float product to Double when adding its unsuffixed
            // 1e-3 literal. Keep the conversion AFTER the multiplication.
            if boundary && isOpaque(q) {
                Self.fill(&m.cover,d*4,Int(ceil(Double(a0*16)-1e-3)),Int(ceil(Double(b0*16)-1e-3)),Int(floor(Double(a1*16)+1e-3)),Int(floor(Double(b1*16)+1e-3)))
            }
            if q.cull >= 0 {
                (a0,b0,a1,b1) = Self.bounds2(q,Int(q.cull))
                let ia0 = min(15,Int(floor(Double(a0*16)+1e-3))), ib0 = min(15,Int(floor(Double(b0*16)+1e-3)))
                let ia1 = max(ia0+1,Int(ceil(Double(a1*16)-1e-3))), ib1 = max(ib0+1,Int(ceil(Double(b1*16)-1e-3)))
                Self.fill(&m.cullCells,i*4,ia0,ib0,ia1,ib1)
            }
        }
        var shell = true, opaqueShell = true
        for d in 0..<6 {
            if first[d] < 0 { shell = false; break }
            if !isOpaque(quads[first[d]]) { opaqueShell = false }
        }
        if shell && (onlyShell || (opaqueShell && inside)) {
            m.fullCube = true; m.opaque = opaqueShell
            var faces = [FaceKey](repeating: FaceKey(),count: 6)
            for d in 0..<6 {
                let q = quads[first[d]]
                faces[d] = FaceKey(layer: Int(q.t0.z),color: q.color)
                faces[d].uvMap = CubeUv.mapOf(q,d); faces[d].tint = q.tint
                if second[d] >= 0 && Int(quads[second[d]].t0.z) >= 0 {
                    let o = quads[second[d]]
                    faces[d].overlay = Int(o.t0.z)+1; faces[d].overlayColor = o.color
                    faces[d].overlayTint = o.tint; faces[d].overlayUvMap = CubeUv.mapOf(o,d)
                }
            }
            m.cubeFaces = faces
        }
        return m
    }
}

// Placeholder geometry only: keep this private until the block-entity renderer
// ports its full catalog. This predicate is the CodeDrawn subset at the source revision.
private enum BlockEntityBoxes {
    static func wanted(_ b: BlockModelBaker, _ path: String) -> Bool {
        if b.entityBoxes { return true }
        let codeDrawn = ["chest","trapped_chest","ender_chest","bell","decorated_pot","conduit","end_portal","end_gateway"].contains(path) ||
            path.hasSuffix("copper_chest") || path.hasSuffix("shulker_box") || path.hasSuffix("copper_golem_statue") || path.hasSuffix("_banner") || path.hasSuffix("_skull") ||
            ["zombie","player","creeper","dragon","piglin"].contains { path == $0+"_head" || path == $0+"_wall_head" }
        return !codeDrawn
    }
    static func facing(_ p: [String:String]) -> Double { p["facing"] == "east" ? 90 : p["facing"] == "south" ? 180 : p["facing"] == "west" ? 270 : 0 }
    static func rotation16(_ p: [String:String]) -> Double { Double(Int(p["rotation"] ?? "") ?? 0)*22.5 }
    static func headColor(_ path: String) -> Color32 {
        if path.hasPrefix("wither_skeleton") { return Color32(52,52,52) }
        if path.hasPrefix("skeleton") { return Color32(205,205,195) }
        if path.hasPrefix("zombie") { return Color32(84,136,74) }
        if path.hasPrefix("creeper") { return Color32(96,170,84) }
        if path.hasPrefix("piglin") { return Color32(226,160,146) }
        if path.hasPrefix("dragon") { return Color32(36,36,40) }
        return Color32(190,140,110)
    }
    static func add(_ b: BlockModelBaker, _ path: String, _ p: [String:String], _ model: BlockModelBaker.Resolved?, _ state: String, _ q: inout [BakedQuad]) {
        if b.onlyEntityBoxes { q.removeAll() }
        if !wanted(b,path) { return }
        let particle = b.particleOf(model,state)
        if path == "bell" {
            if let particle { b.box(SIMD3(4,4,4),SIMD3(12,6,12),particle,0,&q); b.box(SIMD3(5,6,5),SIMD3(11,13,11),particle,0,&q) }
            return
        }
        if !q.isEmpty { return }
        if path.hasSuffix("chest") {
            guard let particle else { return }
            b.box(SIMD3(p["type"] == "right" ? 0 : 1,0,1),SIMD3(p["type"] == "left" ? 16 : 15,14,15),particle,facing(p),&q)
        } else if path.hasSuffix("shulker_box") {
            if let particle { b.box(.zero,SIMD3(repeating: 16),particle,0,&q) }
        } else if path.hasSuffix("_skull") || path.hasSuffix("_head") {
            let key = FaceKey(layer: -1,color: headColor(path))
            if path.contains("_wall_") { b.box(SIMD3(4,4,8),SIMD3(12,12,16),key,facing(p),&q) }
            else { b.box(SIMD3(4,0,4),SIMD3(12,8,12),key,rotation16(p),&q) }
        } else if path.hasSuffix("_banner") {
            let suffix = path.hasSuffix("_wall_banner") ? "_wall_banner" : "_banner"
            let cut = path.range(of: suffix)!.lowerBound
            var cloth = b.texture("block/"+path[..<cut]+"_wool",state)
            if cloth.layer < 0 { cloth = FaceKey(layer: -1,color: BlockRules.flatColor(path)) }
            if path.hasSuffix("_wall_banner") {
                if let particle { b.box(SIMD3(1,14,13.5),SIMD3(15,16,15.5),particle,facing(p),&q) }
                b.box(SIMD3(1,-12,14),SIMD3(15,14,15),cloth,facing(p),&q)
            } else {
                if let particle { b.box(SIMD3(7,0,7),SIMD3(9,28,9),particle,rotation16(p),&q); b.box(SIMD3(1,26,9),SIMD3(15,28,11),particle,rotation16(p),&q) }
                b.box(SIMD3(1,4,9.5),SIMD3(15,26,10.5),cloth,rotation16(p),&q)
            }
        } else if path == "decorated_pot" {
            if let particle { b.box(SIMD3(1,0,1),SIMD3(15,13,15),particle,0,&q); b.box(SIMD3(4,13,4),SIMD3(12,16,12),particle,0,&q) }
        } else if path == "conduit" {
            if let particle { b.box(SIMD3(5,5,5),SIMD3(11,11,11),particle,0,&q) }
        } else if path.hasSuffix("copper_golem_statue") {
            if let particle { b.box(SIMD3(3,0,4),SIMD3(13,15,12),particle,facing(p),&q) }
        } else if path == "end_portal" { b.box(.zero,SIMD3(16,12,16),FaceKey(layer: -1,color: Color32(14,18,34)),0,&q) }
        else if path == "end_gateway" { b.box(.zero,SIMD3(repeating: 16),FaceKey(layer: -1,color: Color32(14,18,34)),0,&q) }
        else if let particle {
            if path.hasSuffix("_bed") { b.box(.zero,SIMD3(16,9,16),particle,0,&q) }
            else if path.hasSuffix("_wall_hanging_sign") { b.box(SIMD3(1,0,7),SIMD3(15,10,9),particle,facing(p),&q) }
            else if path.hasSuffix("_hanging_sign") { b.box(SIMD3(1,0,7),SIMD3(15,10,9),particle,rotation16(p),&q) }
            else if path.hasSuffix("_wall_sign") { b.box(SIMD3(0,4.5,14),SIMD3(16,12.5,16),particle,facing(p),&q) }
            else if path.hasSuffix("_sign") { b.box(SIMD3(7,0,7),SIMD3(9,9,9),particle,rotation16(p),&q); b.box(SIMD3(0,8,7),SIMD3(16,16,9),particle,rotation16(p),&q) }
        }
    }
}
