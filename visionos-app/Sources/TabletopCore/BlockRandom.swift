// Port of quest-app/Assets/Scripts/World/BlockModelBaker.cs (BlockRandom, CubeUv) at f7d4a0f.
// Minecraft coordinates and C# Float operation order; no Unity conversion.
import Foundation

public enum BlockRandom {
    public static func seed(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
        var l = Int64(Int32(truncatingIfNeeded: x) &* 3129871) ^ (Int64(Int32(truncatingIfNeeded: z)) &* 116129781) ^ Int64(Int32(truncatingIfNeeded: y))
        l = (l &* l &* 42317861) &+ (l &* 11)
        return l >> 16
    }

    public struct JavaRandom: Sendable {
        private static let mask: Int64 = (1 << 48) - 1
        private var s: Int64
        public init(_ seed: Int64) { s = (seed ^ 0x5DEECE66D) & Self.mask }
        public mutating func setSeed(_ seed: Int64) { s = (seed ^ 0x5DEECE66D) & Self.mask }
        public mutating func next(_ bits: Int) -> Int32 {
            s = (s &* 0x5DEECE66D &+ 0xB) & Self.mask
            return Int32(truncatingIfNeeded: s >> (48 - bits))
        }
        public mutating func nextInt(_ bound: Int) -> Int {
            precondition(bound > 0 && bound <= Int(Int32.max))
            let b = Int32(bound)
            if b & (b &- 1) == 0 { return Int((Int64(b) * Int64(next(31))) >> 31) }
            while true {
                let bits = next(31), value = bits % b
                if bits &- value &+ (b &- 1) >= 0 { return Int(value) }
            }
        }
        public mutating func nextLong() -> Int64 {
            let hi = next(32), lo = next(32)
            return (Int64(hi) << 32) &+ Int64(lo)
        }
    }

    public static func pick(_ m: BakedModel, _ x: Int, _ y: Int, _ z: Int) -> Int {
        var r = JavaRandom(seed(x,y,z))
        guard let totals = m.randomTotals, let first = totals.first else { return 0 }
        if !m.randomMultipart { return r.nextInt(first) }
        let partSeed = r.nextLong()
        var index = 0
        for total in totals { r.setSeed(partSeed); index = index * total + r.nextInt(total) }
        return index
    }

    private static let offsetXyz: Set<String> = ["short_grass", "fern", "short_dry_grass", "tall_dry_grass", "small_dripleaf"]
    private static let offsetXz: Set<String> = [
        "mangrove_propagule", "tall_seagrass", "dandelion", "golden_dandelion", "torchflower", "poppy", "blue_orchid", "allium", "azure_bluet",
        "red_tulip", "orange_tulip", "white_tulip", "pink_tulip", "oxeye_daisy", "cornflower", "wither_rose", "lily_of_the_valley", "sunflower",
        "lilac", "rose_bush", "peony", "tall_grass", "large_fern", "pitcher_plant", "bamboo_sapling", "bamboo", "warped_roots", "nether_sprouts",
        "crimson_roots", "pointed_dripstone", "sulfur_spike", "hanging_roots", "open_eyeblossom", "closed_eyeblossom"
    ]
    public static func setOffset(_ m: inout BakedModel, _ path: String) {
        m.offsetKind = offsetXyz.contains(path) ? 2 : offsetXz.contains(path) ? 1 : 0
        guard m.offsetKind != 0 else { return }
        if path == "pointed_dripstone" || path == "sulfur_spike" { m.maxHorizontalOffset = 0.125 }
        if path == "small_dripleaf" { m.maxVerticalOffset = 0.1 }
        if var variants = m.variants {
            for i in variants.indices {
                variants[i].offsetKind = m.offsetKind
                variants[i].maxHorizontalOffset = m.maxHorizontalOffset
                variants[i].maxVerticalOffset = m.maxVerticalOffset
            }
            m.variants = variants
        }
    }
    public static func offset(_ m: BakedModel, _ x: Int, _ z: Int) -> SIMD3<Float> {
        guard m.offsetKind != 0 else { return .zero }
        let s = seed(x,0,z), h = Double(m.maxHorizontalOffset)
        let dx = min(h,max(-h,(Double(Float(s & 15) / 15) - 0.5) * 0.5))
        let dz = min(h,max(-h,(Double(Float((s >> 8) & 15) / 15) - 0.5) * 0.5))
        let dy = m.offsetKind == 2 ? (Double(Float((s >> 4) & 15) / 15) - 1) * Double(m.maxVerticalOffset) : 0
        return SIMD3(Float(dx),Float(dy),Float(dz))
    }
}

public enum CubeUv {
    public static func canon(_ dir: Int, _ p: SIMD3<Float>) -> (Float,Float) {
        switch dir {
        case 0: (p.z,p.y)
        case 1: (-p.z,p.y)
        case 2: (p.x,p.z)
        case 3: (p.x,-p.z)
        case 4: (-p.x,p.y)
        default: (p.x,p.y)
        }
    }
    public static func greedy(_ dir: Int, _ p: SIMD3<Float>, _ k: FaceKey) -> SIMD3<Float> {
        var (u,v) = canon(dir,p)
        if k.uvMap & 1 != 0 { swap(&u,&v) }
        if k.uvMap & 2 != 0 { u = -u }
        if k.uvMap & 4 != 0 { v = -v }
        return SIMD3(u,v,Float(k.layer >= 0 && k.random != 0 ? k.layer + RandomUv.layerStride * Int(k.random) : k.layer))
    }
    public static func mapOf(_ q: BakedQuad, _ dir: Int) -> UInt8 {
        let (u0,v0) = canon(dir,q.p0), (u1,v1) = canon(dir,q.p1), (u3,v3) = canon(dir,q.p3)
        let cu1 = u1-u0, cv1 = v1-v0, cu2 = u3-u0, cv2 = v3-v0
        let bu1 = q.t1.x-q.t0.x, bv1 = q.t1.y-q.t0.y, bu2 = q.t3.x-q.t0.x, bv2 = q.t3.y-q.t0.y
        let det = cu1*cv2-cu2*cv1
        if abs(det) < 1e-6 { return 0 }
        let m00 = (bu1*cv2-bu2*cv1)/det, m01 = (bu2*cu1-bu1*cu2)/det
        let m10 = (bv1*cv2-bv2*cv1)/det, m11 = (bv2*cu1-bv1*cu2)/det
        if abs(m00) >= abs(m01) { return (m00 < 0 ? 2 : 0) | (m11 < 0 ? 4 : 0) }
        return 1 | (m01 < 0 ? 2 : 0) | (m10 < 0 ? 4 : 0)
    }
}
