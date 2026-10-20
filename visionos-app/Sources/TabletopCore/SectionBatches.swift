// Port of quest-app/Assets/Scripts/World/SectionBatches.cs at 281c614.
// CPU structures only. Positions and indices retain tabletop handedness; Metal
// upload/packing is a separate concern (SIMD3's Swift stride is not a GPU layout).
import Foundation
import simd

public struct BatchVertex: Sendable {
    public var pos: SIMD3<Float>
    public var nx: Int8 = 0
    public var ny: Int8 = 0
    public var nz: Int8 = 0
    public var nw: Int8 = 0
    public var color: Color32
    public var uv: SIMD3<Float>
    public init(pos: SIMD3<Float>, color: Color32, uv: SIMD3<Float>) { self.pos = pos; self.color = color; self.uv = uv }
}
public struct SectionMesh: Sendable {
    public let verts: [BatchVertex]
    public let indices: [Int]
    public let opaque, solid, transparent, waterBack, quads: Int
    public static func from(_ d: MeshData, _ section: SIMD3<Int>, solidLayers: Set<Int> = [], solidPass: Bool = true) -> SectionMesh? {
        guard !d.verts.isEmpty else { return nil }
        let b = section &* SIMD3(repeating: 16), base = SIMD3<Float>(Float(b.x),Float(b.y),Float(b.z))
        var verts = d.verts.indices.map { i -> BatchVertex in
            var v = BatchVertex(pos: d.verts[i]-base,color: d.colors[i],uv: d.uvs[i])
            let code = d.light.count == d.verts.count ? d.light[i] : 240
            v.nw = Int8(truncatingIfNeeded: ((Int(code)+15)&255)-128); return v
        }
        var acc = [SIMD3<Float>](repeating: .zero,count: verts.count)
        // Deliberately no Z mirror and no winding flip (ROADMAP 3.6).
        let all = d.opaque+d.transparent+d.waterBack
        for i in stride(from: 0,to: all.count,by: 3) where i+2 < all.count {
            let a = all[i], b = all[i+1], c = all[i+2]
            let cross = simd_cross(verts[b].pos-verts[a].pos,verts[c].pos-verts[a].pos), len = simd_length(cross)
            if len < 1e-12 { continue }
            let n = cross/len
            acc[a] += n; acc[b] += n; acc[c] += n
        }
        for i in verts.indices {
            let len = simd_length(acc[i]); if len < 1e-3 { continue }
            let n = acc[i]/len
            func snorm(_ v: Float) -> Int8 { Int8((max(-1,min(1,v))*127).rounded(.toNearestOrEven)) }
            verts[i].nx = snorm(n.x); verts[i].ny = snorm(n.y); verts[i].nz = snorm(n.z)
        }
        var solid: [Int] = [], cutout: [Int] = []
        for i in stride(from: 0,to: d.opaque.count,by: 3) where i+2 < d.opaque.count {
            let tri = Array(d.opaque[i..<i+3]), uvz = verts[tri[0]].uv.z
            if solidPass && tri.allSatisfy({ verts[$0].color.a == 255 }) && SolidLayers.face(uvz,solidLayers) { solid.append(contentsOf: tri) }
            else { cutout.append(contentsOf: tri) }
        }
        return SectionMesh(verts: verts,indices: solid+cutout+d.transparent+d.waterBack,opaque: d.opaque.count,solid: solid.count,transparent: d.transparent.count,waterBack: d.waterBack.count,quads: verts.count/4-d.waterBack.count/6)
    }
    public var bytes: Int { verts.count*MemoryLayout<BatchVertex>.stride+indices.count*MemoryLayout<Int>.stride }
}

public struct BatchLayout: Sendable {
    public let origin, sections: SIMD3<Int>
    public let columns: Int
    public init(_ origin: SIMD3<Int>, _ dims: SIMD3<Int>, _ columns: Int = 2) {
        self.origin = origin; self.sections = SectionPlan.sections(dims); self.columns = max(1,columns)
    }
    static func floorDiv(_ a: Int, _ b: Int) -> Int { let q = a/b; return a%b < 0 ? q-1 : q }
    var sx: Int { Self.floorDiv(origin.x,16) }
    var sz: Int { Self.floorDiv(origin.z,16) }
    public var sy: Int { Self.floorDiv(origin.y,16) }
    public func keyOf(_ section: SIMD3<Int>) -> SIMD3<Int> { SIMD3(Self.floorDiv(sx+section.x,columns),0,Self.floorDiv(sz+section.z,columns)) }
    public func first(_ key: SIMD3<Int>) -> SIMD3<Int> { SIMD3(key.x*columns-sx,0,key.z*columns-sz) }
    public func sectionsOf(_ key: SIMD3<Int>) -> [SIMD3<Int>] {
        let f = first(key), x0 = max(0,f.x), x1 = min(sections.x,f.x+columns), z0 = max(0,f.z), z1 = min(sections.z,f.z+columns)
        guard x1 > x0, z1 > z0, sections.y > 0 else { return [] }
        var result: [SIMD3<Int>] = []
        for x in x0..<x1 { for z in z0..<z1 { for y in 0..<sections.y { result.append(SIMD3(x,y,z)) } } }
        return result
    }
    public func covers(_ key: SIMD3<Int>) -> Bool {
        let f = first(key)
        return sections.y > 0 && f.x < sections.x && f.x+columns > 0 && f.z < sections.z && f.z+columns > 0
    }
    public func allKeys() -> [SIMD3<Int>] {
        guard sections.x > 0, sections.z > 0 else { return [] }
        let a = keyOf(.zero), b = keyOf(SIMD3(sections.x-1,0,sections.z-1))
        var result: [SIMD3<Int>] = []
        for x in a.x...b.x { for z in a.z...b.z { result.append(SIMD3(x,0,z)) } }; return result
    }
    public func position(_ key: SIMD3<Int>, _ y0: Int) -> SIMD3<Float> {
        let f = first(key); return SIMD3(Float(f.x*16),Float((y0-sy)*16),Float(f.z*16))
    }
    public func offset(_ section: SIMD3<Int>, _ key: SIMD3<Int>, _ y0: Int) -> SIMD3<Float> {
        let f = first(key); return SIMD3(Float((section.x-f.x)*16),Float((sy+section.y-y0)*16),Float((section.z-f.z)*16))
    }
}
public struct BatchData: Sendable {
    public var verts: [BatchVertex] = []
    public var indices: [Int] = []
    public var opaque = 0, solid = 0, transparent = 0, waterBack = 0, quads = 0, sections = 0
    public var min = SIMD3<Float>.zero, max = SIMD3<Float>.zero
    public var ms = 0.0
    public var vertCount: Int { verts.count }
    public var indexCount: Int { indices.count }
    public static func assemble(_ parts: [(mesh: SectionMesh, offset: SIMD3<Float>)]) -> BatchData {
        let start = ContinuousClock.now
        var b = BatchData(), s: [Int] = [], o: [Int] = [], t: [Int] = [], w: [Int] = []
        b.sections = parts.count
        for (m,offset) in parts {
            let at = b.verts.count
            for var v in m.verts { v.pos += offset; b.verts.append(v) }
            s.append(contentsOf: m.indices[..<m.solid].map { $0+at })
            o.append(contentsOf: m.indices[m.solid..<m.opaque].map { $0+at })
            t.append(contentsOf: m.indices[m.opaque..<m.opaque+m.transparent].map { $0+at })
            w.append(contentsOf: m.indices[(m.opaque+m.transparent)...].map { $0+at })
            b.quads += m.quads
        }
        b.solid = s.count; b.opaque = s.count+o.count; b.transparent = t.count; b.waterBack = w.count; b.indices = s+o+t+w
        if let first = b.verts.first {
            b.min = first.pos; b.max = first.pos
            for v in b.verts { b.min = simd_min(b.min,v.pos); b.max = simd_max(b.max,v.pos) }
        }
        let d = start.duration(to: .now).components; b.ms = Double(d.seconds)*1000+Double(d.attoseconds)/1e15
        return b
    }
    public func drawCalls(_ underwater: Bool = false) -> Int { (solid > 0 ? 1 : 0)+(opaque > solid ? 1 : 0)+(transparent > 0 ? 1 : 0)+(underwater && waterBack > 0 ? 1 : 0) }
    public var bytes: Int { verts.count*MemoryLayout<BatchVertex>.stride+indices.count*MemoryLayout<Int>.stride }
    public mutating func release() { verts = []; indices = [] }
}

// Minimal engine-free box used by batch scheduling; max is exclusive.
public struct SectionBox: Sendable {
    public var min, max: SIMD3<Int>
    public init(min: SIMD3<Int>, max: SIMD3<Int>) { self.min = min; self.max = max }
    public static let all = SectionBox(min: SIMD3(repeating: Int.min/2),max: SIMD3(repeating: Int.max/2))
    public func contains(_ p: SIMD3<Int>) -> Bool { p.x >= min.x && p.y >= min.y && p.z >= min.z && p.x < max.x && p.y < max.y && p.z < max.z }
}
public enum BatchRules {
    public static let columns = 2
    public static func ready(_ sectionsPending: Bool, _ dirtySince: Float, _ now: Float, _ maxWait: Float, _ staging: Bool) -> Bool { !sectionsPending || (!staging && now-dirtySince >= maxWait) }
    public static func offScreen(_ layout: BatchLayout, _ key: SIMD3<Int>, _ visible: SectionBox) -> Bool {
        let f = layout.first(key)
        return f.x+layout.columns <= visible.min.x || f.x >= visible.max.x || f.z+layout.columns <= visible.min.z || f.z >= visible.max.z
    }
    public static func sectionsPending(_ layout: BatchLayout, _ key: SIMD3<Int>, _ busy: Set<SIMD3<Int>>, _ dirty: Set<SIMD3<Int>>, _ scope: SectionBox, _ keep: SectionBox, _ visible: SectionBox, _ staging: Bool) -> Bool {
        let off = !staging && offScreen(layout,key,visible)
        return layout.sectionsOf(key).contains { busy.contains($0) || (dirty.contains($0) && (scope.contains($0) || (off && keep.contains($0)))) }
    }
    public static func afterRekey(_ before: BatchLayout, _ after: BatchLayout, _ shiftSections: SIMD3<Int>, _ held: Set<SIMD3<Int>>, _ batches: Set<SIMD3<Int>>) -> (dirty: Set<SIMD3<Int>>, gone: Set<SIMD3<Int>>) {
        var dirty: Set<SIMD3<Int>> = []
        for k in held where !SectionPlan.contains(k &- shiftSections,after.sections) { dirty.insert(before.keyOf(k)) }
        let gone = Set(batches.filter { !after.covers($0) }); dirty.subtract(gone)
        return (dirty,gone)
    }
}
