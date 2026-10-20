// Port of quest-app/Assets/Scripts/World/SectionPlan.cs at f63878e.
public struct SectionPlan: Sendable {
    public var rekey = false
    public var shiftBlocks = SIMD3<Int>.zero
    public var shiftSections = SIMD3<Int>.zero
    public var mesh: Set<SIMD3<Int>> = []
    public var refresh: Set<SIMD3<Int>> = []
    public var kept = 0
    public var compared: Int64 = 0
    public init() {}
    public static func sections(_ dims: SIMD3<Int>) -> SIMD3<Int> {
        SIMD3((dims.x + 15) / 16, (dims.y + 15) / 16, (dims.z + 15) / 16)
    }
    static func keys(_ n: SIMD3<Int>) -> [SIMD3<Int>] {
        guard n.x > 0 && n.y > 0 && n.z > 0 else { return [] }
        var result: [SIMD3<Int>] = []
        for x in 0..<n.x { for y in 0..<n.y { for z in 0..<n.z { result.append(SIMD3(x,y,z)) } } }
        return result
    }
    static func contains(_ k: SIMD3<Int>, _ n: SIMD3<Int>) -> Bool {
        k.x >= 0 && k.y >= 0 && k.z >= 0 && k.x < n.x && k.y < n.y && k.z < n.z
    }
    public static func canRekey(_ oldWorld: String, _ oldOrigin: SIMD3<Int>, _ oldDims: SIMD3<Int>, _ newWorld: String, _ newOrigin: SIMD3<Int>, _ newDims: SIMD3<Int>) -> Bool {
        guard oldWorld == newWorld else { return false }
        for a in 0..<3 {
            let (d, overflow) = newOrigin[a].subtractingReportingOverflow(oldOrigin[a])
            guard !overflow else { return false }
            let (end, endOverflow) = d.addingReportingOverflow(newDims[a])
            if endOverflow || d % WorldModel.section != 0 || d >= oldDims[a] || end <= 0 { return false }
        }
        return true
    }
    static func extent(_ d: Int, _ k: Int) -> Int { min(16, d - k * 16) }
    public static func compute(_ old: WorldModel, _ new: ChunkSnapshot, _ stale: Set<SIMD3<Int>>? = nil, _ listed: Set<SIMD3<Int>>? = nil) -> SectionPlan {
        var p = SectionPlan()
        let n = sections(new.dims)
        guard old.loaded, canRekey(old.world,old.origin,old.dims,new.world,new.origin,new.dims) else {
            p.mesh = Set(keys(n)); return p
        }
        p.rekey = true; p.shiftBlocks = new.origin &- old.origin
        p.shiftSections = p.shiftBlocks / SIMD3(repeating: 16)
        var idx: [String: Int] = [:]
        if listed == nil { for (i,s) in new.palette.enumerated() where idx[s] == nil { idx[s] = i } }
        let remap = old.palette.map { idx[$0] ?? -1 }
        let on = sections(old.dims)
        for k in keys(n) {
            let ko = k &+ p.shiftSections
            var inOld = contains(ko,on)
            if inOld { for a in 0..<3 where extent(new.dims[a],k[a]) != extent(old.dims[a],ko[a]) { inOld = false } }
            var changed = !inOld || (stale?.contains(ko) ?? false)
            if !changed {
                if let listed { changed = listed.contains(k) }
                else { changed = !same(old,ko,new,k,remap,&p.compared) }
            }
            if changed { p.mesh.insert(k) } else { p.kept += 1 }
        }
        for k in p.mesh {
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                let b = k &+ SIMD3(dx,dy,dz)
                if contains(b,n) && !p.mesh.contains(b) { p.refresh.insert(b) }
            } } }
        }
        if old.dims != new.dims {
            for k in keys(n) where !p.mesh.contains(k) && !p.refresh.contains(k) {
                var lost = false
                for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                    let b = k &+ SIMD3(dx,dy,dz)
                    if !contains(b,n) && contains(b &+ p.shiftSections,on) { lost = true }
                } } }
                if lost { p.refresh.insert(k) }
            }
        }
        return p
    }
    static func same(_ old: WorldModel, _ ko: SIMD3<Int>, _ new: ChunkSnapshot, _ k: SIMD3<Int>, _ remap: [Int], _ compared: inout Int64) -> Bool {
        if (old.light == nil) != (new.light == nil) { return false }
        let o = ko &* SIMD3(repeating: 16), b = k &* SIMD3(repeating: 16)
        let sx = extent(new.dims.x,k.x), sy = extent(new.dims.y,k.y), sz = extent(new.dims.z,k.z)
        for y in 0..<sy { for z in 0..<sz {
            let oi = ((o.y+y) * old.dims.z+o.z+z) * old.dims.x+o.x
            let ni = ((b.y+y) * new.dims.z+b.z+z) * new.dims.x+b.x
            for x in 0..<sx {
                compared += 1
                let ov = Int(old.grid[oi+x])
                if ov >= remap.count || remap[ov] != Int(new.grid[ni+x]) { return false }
                if let nl = new.light, let ol = old.light, nl[ni+x] != ol[oi+x] { return false }
            }
        } }
        return true
    }
}
