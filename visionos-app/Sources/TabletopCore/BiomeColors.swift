// Port of quest-app/Assets/Scripts/World/BiomeColors.cs at f7d4a0f.
// Colormaps and snapshot tints are immutable Sendable values, owned by each world.
import Foundation

public struct BiomeColormaps: Sendable {
    public let grass, foliage, dryFoliage: [Int]?
    public init(grass: [Int]? = nil, foliage: [Int]? = nil, dryFoliage: [Int]? = nil) {
        self.grass = grass?.count == 65536 ? grass : nil
        self.foliage = foliage?.count == 65536 ? foliage : nil
        self.dryFoliage = dryFoliage?.count == 65536 ? dryFoliage : nil
    }
}

/// Vanilla BIOME_INFO_NOISE, including java.util.Random's wrapping rejection check.
public enum SwampNoise {
    private static let p: [UInt8] = {
        var seed: Int64 = (2345 ^ 0x5DEECE66D) & ((1 << 48)-1)
        func next(_ bits: Int) -> Int32 {
            seed = (seed &* 0x5DEECE66D &+ 0xB) & ((1 << 48)-1)
            return Int32(seed >> (48-bits))
        }
        func nextInt(_ bound: Int32) -> Int {
            if bound & (bound-1) == 0 { return Int((Int64(bound)*Int64(next(31))) >> 31) }
            while true {
                let bits = next(31), val = bits % bound
                if bits &- val &+ (bound-1) >= 0 { return Int(val) }
            }
        }
        for _ in 0..<3 { _ = next(26); _ = next(27) }
        var p = (0..<256).map(UInt8.init)
        for i in 0..<256 { let j = nextInt(Int32(256-i)); p.swapAt(i,i+j) }
        return p
    }()
    private static let grad = [(1,1),(-1,1),(1,-1),(-1,-1),(1,0),(-1,0),(1,0),(-1,0),(0,1),(0,-1),(0,1),(0,-1)]
    private static let f2 = 0.5*(sqrt(3.0)-1.0), g2 = (3.0-sqrt(3.0))/6.0
    private static func perm(_ i: Int) -> Int { Int(p[i&255]) }
    private static func corner(_ g: Int, _ x: Double, _ y: Double) -> Double {
        var d = 0.5-x*x-y*y
        if d < 0 { return 0 }
        d *= d
        return d*d*(Double(grad[g].0)*x+Double(grad[g].1)*y)
    }
    public static func get(_ x: Double, _ y: Double) -> Float {
        let s = (x+y)*f2
        let i = Int(floor(x+s)), j = Int(floor(y+s)), t = Double(i+j)*g2
        let x0 = x-(Double(i)-t), y0 = y-(Double(j)-t)
        let i1 = x0 > y0 ? 1 : 0, j1 = x0 > y0 ? 0 : 1
        let x1 = x0-Double(i1)+g2, y1 = y0-Double(j1)+g2, x2 = x0-1+2*g2, y2 = y0-1+2*g2
        let ii = i&255, jj = j&255
        let a = perm(ii+perm(jj))%12, b = perm(ii+i1+perm(jj+j1))%12, c = perm(ii+1+perm(jj+1))%12
        return Float(70*(corner(a,x0,y0)+corner(b,x1,y1)+corner(c,x2,y2)))
    }
}

/// A snapshot's tint inputs. Pure reads are safe on concurrent mesh workers.
/// Uniform quart windows use the C# fast path; varying windows average 25 columns.
public struct BiomeTints: Sendable {
    private let grid: BiomeGrid
    private let origin, dims: SIMD3<Int>
    private let info: [BiomeInfo]
    private let colormaps: BiomeColormaps
    public init(_ g: BiomeGrid, origin: SIMD3<Int>, dims: SIMD3<Int>, colormaps: BiomeColormaps = BiomeColormaps()) {
        grid = g; self.origin = origin; self.dims = dims; self.colormaps = colormaps
        info = g.palette.enumerated().map { i,key in BiomeColors.info(key,g.climate.flatMap { i < $0.count ? $0[i] : nil }) }
    }
    public func tint(_ kind: TintKind, _ x: Int, _ y: Int, _ z: Int) -> Int {
        guard kind != .none, dims.x > 0, dims.y > 0, dims.z > 0,
              grid.qDims.x > 0, grid.qDims.y > 0, grid.qDims.z > 0,
              !grid.cells.isEmpty, !info.isEmpty else { return -1 }
        let x = max(0,min(dims.x-1,x)), y = max(0,min(dims.y-1,y)), z = max(0,min(dims.z-1,z))
        let wy = origin.y+y, r = BiomeColors.blendRadius
        let x0 = max(0,x-r), x1 = min(dims.x-1,x+r), z0 = max(0,z-r), z1 = min(dims.z-1,z+r)
        let first = grid.at(origin.x+x0,wy,origin.z+z0)
        guard first < info.count else { return -1 }
        var uniform = !BiomeColors.positionDependent(info[first],kind)
        for qz in ((origin.z+z0) >> 2)...((origin.z+z1) >> 2) where uniform {
            for qx in ((origin.x+x0) >> 2)...((origin.x+x1) >> 2) where uniform {
                if grid.at(qx << 2,wy,qz << 2) != first { uniform = false }
            }
        }
        if uniform { return BiomeColors.colorOf(info[first],kind,origin.x+x,origin.z+z,colormaps: colormaps) }
        var red = 0, green = 0, blue = 0
        let n = (2*r+1)*(2*r+1)
        for dz in -r...r { for dx in -r...r {
            let sx = max(0,min(dims.x-1,x+dx)), sz = max(0,min(dims.z-1,z+dz))
            let wx = origin.x+sx, wz = origin.z+sz, i = grid.at(wx,wy,wz)
            guard i < info.count else { return -1 }
            let c = BiomeColors.colorOf(info[i],kind,wx,wz,colormaps: colormaps)
            if c < 0 { return -1 }
            red += (c >> 16)&255; green += (c >> 8)&255; blue += c&255
        } }
        return (red/n) << 16 | (green/n) << 8 | (blue/n)
    }
}
public enum GrassModifier: UInt8, Sendable { case none, darkForest, swamp }
public struct BiomeInfo: Sendable {
    public let temperature, downfall: Float
    public let grass, foliage, dryFoliage, water: Int
    public let modifier: GrassModifier
    public init(temperature: Float = 0.8, downfall: Float = 0.4, water: Int = 0x3F76E4, grass: Int = -1, foliage: Int = -1, dryFoliage: Int = -1, modifier: GrassModifier = .none) {
        self.temperature = temperature; self.downfall = downfall; self.water = water
        self.grass = grass; self.foliage = foliage; self.dryFoliage = dryFoliage; self.modifier = modifier
    }
}
public enum BiomeColors {
    public static let blendRadius = 2
    public static func lookup(_ map: [Int]?, _ temperature: Float, _ downfall: Float) -> Int {
        guard let map else { return -1 }
        let t = min(max(Double(temperature),0),1)
        var d = min(max(Double(downfall),0),1); d *= t
        let i = Int((1-t)*255), j = Int((1-d)*255), k = j << 8 | i
        return k >= map.count ? -1 : map[k] & 0xFFFFFF
    }
    public static func colorOf(_ b: BiomeInfo, _ kind: TintKind, _ wx: Int, _ wz: Int, colormaps: BiomeColormaps = BiomeColormaps()) -> Int {
        switch kind {
        case .water: return b.water
        case .foliage: return b.foliage >= 0 ? b.foliage : lookup(colormaps.foliage,b.temperature,b.downfall)
        case .dryFoliage: return b.dryFoliage >= 0 ? b.dryFoliage : lookup(colormaps.dryFoliage,b.temperature,b.downfall)
        case .grass:
            if b.modifier == .swamp { return SwampNoise.get(Double(wx)*0.0225,Double(wz)*0.0225) < -0.1 ? 0x4C763C : 0x6A7039 }
            var c = b.grass >= 0 ? b.grass : lookup(colormaps.grass,b.temperature,b.downfall)
            if c >= 0 && b.modifier == .darkForest { c = ((c & 0xFEFEFE)+0x28340A) >> 1 }
            return c
        default: return -1
        }
    }
    public static func positionDependent(_ b: BiomeInfo, _ kind: TintKind) -> Bool { kind == .grass && b.modifier == .swamp }
    public static func blockTint(_ state: String, fixedColor: inout Color32?) -> TintKind {
        fixedColor = nil
        switch BlockRules.path(state) {
        case "grass_block", "short_grass", "tall_grass", "fern", "large_fern", "potted_fern", "bush", "sugar_cane", "pink_petals", "wildflowers": return .grass
        case "oak_leaves", "jungle_leaves", "acacia_leaves", "dark_oak_leaves", "mangrove_leaves", "vine": return .foliage
        case "spruce_leaves": fixedColor = rgb(0x619961)
        case "birch_leaves": fixedColor = rgb(0x80A755)
        case "lily_pad": fixedColor = rgb(0x208030)
        case "attached_melon_stem", "attached_pumpkin_stem": fixedColor = rgb(0xE0C71C)
        case "melon_stem", "pumpkin_stem":
            let age = prop(state,"age")
            fixedColor = Color32(UInt8(truncatingIfNeeded: age*32),UInt8(truncatingIfNeeded: 255-age*8),UInt8(truncatingIfNeeded: age*4))
        case "redstone_wire":
            let f = Float(prop(state,"power"))/15
            let r = f*0.6+(f > 0 ? 0.4 : 0.3), g = max(0,min(1,f*f*0.7-0.5)), b = max(0,min(1,f*f*0.6-0.7))
            fixedColor = Color32(UInt8(truncatingIfNeeded: Int(r*255)),UInt8(truncatingIfNeeded: Int(g*255)),UInt8(truncatingIfNeeded: Int(b*255)))
        case "leaf_litter": return .dryFoliage
        case "water", "bubble_column", "water_cauldron": return .water
        default: break
        }
        return .none
    }
    public static func blockTint(_ state: String) -> (TintKind,Color32?) {
        var c: Color32?; let kind = blockTint(state,fixedColor: &c); return (kind,c)
    }
    public static func tinted(_ state: String, _ tintIndex: Int) -> Bool {
        if tintIndex < 0 { return false }
        let p = BlockRules.path(state)
        if p == "pink_petals" || p == "wildflowers" { return tintIndex == 1 }
        let (kind,c) = blockTint(state)
        return tintIndex == 0 && (kind != .none || c != nil)
    }
    private static func prop(_ state: String, _ key: String) -> Int {
        guard let r = state.range(of: key+"=") else { return 0 }
        var v = 0
        for c in state[r.upperBound...].utf8 { if c < 48 || c > 57 { break }; v = v &* 10 &+ Int(c-48) }
        return v
    }
    public static func rgb(_ c: Int) -> Color32 { Color32(UInt8((c >> 16)&255),UInt8((c >> 8)&255),UInt8(c&255)) }
    public static func info(_ key: String, _ climate: [Double]? = nil) -> BiomeInfo {
        if key.hasPrefix("minecraft:"), let b = vanilla[String(key.dropFirst(10))] { return b }
        if let climate, climate.count >= 2 { return BiomeInfo(temperature: Float(climate[0]),downfall: Float(climate[1])) }
        return BiomeInfo()
    }
    public static let vanilla: [String: BiomeInfo] = [
        "badlands": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: 0x90814D,foliage: 0x9E814D,dryFoliage: -1,modifier: .none),
        "bamboo_jungle": BiomeInfo(temperature: 0.95,downfall: 0.9,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "basalt_deltas": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "beach": BiomeInfo(temperature: 0.8,downfall: 0.4,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "birch_forest": BiomeInfo(temperature: 0.6,downfall: 0.6,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "cherry_grove": BiomeInfo(temperature: 0.5,downfall: 0.8,water: 0x5DB7EF,grass: 0xB6DB61,foliage: 0xB6DB61,dryFoliage: -1,modifier: .none),
        "cold_ocean": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3D57D6,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "crimson_forest": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "dappled_forest": BiomeInfo(temperature: 0.6,downfall: 0.6,water: 0x375154,grass: 0xDF6827,foliage: 0xE68E30,dryFoliage: 0x8C3A04,modifier: .none),
        "dark_forest": BiomeInfo(temperature: 0.7,downfall: 0.8,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: 0x7B5334,modifier: .darkForest),
        "deep_cold_ocean": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3D57D6,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "deep_dark": BiomeInfo(temperature: 0.8,downfall: 0.4,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "deep_frozen_ocean": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3938C9,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "deep_lukewarm_ocean": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x45ADF2,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "deep_ocean": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "desert": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "dripstone_caves": BiomeInfo(temperature: 0.8,downfall: 0.4,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "end_barrens": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "end_highlands": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "end_midlands": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "eroded_badlands": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: 0x90814D,foliage: 0x9E814D,dryFoliage: -1,modifier: .none),
        "flower_forest": BiomeInfo(temperature: 0.7,downfall: 0.8,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "forest": BiomeInfo(temperature: 0.7,downfall: 0.8,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "frozen_ocean": BiomeInfo(temperature: 0.0,downfall: 0.5,water: 0x3938C9,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "frozen_peaks": BiomeInfo(temperature: -0.7,downfall: 0.9,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "frozen_river": BiomeInfo(temperature: 0.0,downfall: 0.5,water: 0x3938C9,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "grove": BiomeInfo(temperature: -0.2,downfall: 0.8,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "ice_spikes": BiomeInfo(temperature: 0.0,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "jagged_peaks": BiomeInfo(temperature: -0.7,downfall: 0.9,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "jungle": BiomeInfo(temperature: 0.95,downfall: 0.9,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "lukewarm_ocean": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x45ADF2,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "lush_caves": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "mangrove_swamp": BiomeInfo(temperature: 0.8,downfall: 0.9,water: 0x3A7A6A,grass: -1,foliage: 0x8DB127,dryFoliage: 0x7B5334,modifier: .swamp),
        "meadow": BiomeInfo(temperature: 0.5,downfall: 0.8,water: 0x0E4ECF,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "mushroom_fields": BiomeInfo(temperature: 0.9,downfall: 1.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "nether_wastes": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "ocean": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "old_growth_birch_forest": BiomeInfo(temperature: 0.6,downfall: 0.6,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "old_growth_pine_taiga": BiomeInfo(temperature: 0.3,downfall: 0.8,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "old_growth_spruce_taiga": BiomeInfo(temperature: 0.25,downfall: 0.8,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "pale_garden": BiomeInfo(temperature: 0.7,downfall: 0.8,water: 0x76889D,grass: 0x778272,foliage: 0x878D76,dryFoliage: 0xA0A69C,modifier: .none),
        "plains": BiomeInfo(temperature: 0.8,downfall: 0.4,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "river": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "savanna": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "savanna_plateau": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "small_end_islands": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "snowy_beach": BiomeInfo(temperature: 0.05,downfall: 0.3,water: 0x3D57D6,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "snowy_plains": BiomeInfo(temperature: 0.0,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "snowy_slopes": BiomeInfo(temperature: -0.3,downfall: 0.9,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "snowy_taiga": BiomeInfo(temperature: -0.5,downfall: 0.4,water: 0x3D57D6,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "soul_sand_valley": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "sparse_jungle": BiomeInfo(temperature: 0.95,downfall: 0.8,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "stony_peaks": BiomeInfo(temperature: 1.0,downfall: 0.3,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "stony_shore": BiomeInfo(temperature: 0.2,downfall: 0.3,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "sulfur_caves": BiomeInfo(temperature: 0.8,downfall: 0.4,water: 0x34BF89,grass: 0xABA64F,foliage: -1,dryFoliage: -1,modifier: .none),
        "sunflower_plains": BiomeInfo(temperature: 0.8,downfall: 0.4,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "swamp": BiomeInfo(temperature: 0.8,downfall: 0.9,water: 0x617B64,grass: -1,foliage: 0x6A7039,dryFoliage: 0x7B5334,modifier: .swamp),
        "taiga": BiomeInfo(temperature: 0.25,downfall: 0.8,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "the_end": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "the_void": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "warm_ocean": BiomeInfo(temperature: 0.5,downfall: 0.5,water: 0x43D5EE,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "warped_forest": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "windswept_forest": BiomeInfo(temperature: 0.2,downfall: 0.3,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "windswept_gravelly_hills": BiomeInfo(temperature: 0.2,downfall: 0.3,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "windswept_hills": BiomeInfo(temperature: 0.2,downfall: 0.3,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "windswept_savanna": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: -1,foliage: -1,dryFoliage: -1,modifier: .none),
        "wooded_badlands": BiomeInfo(temperature: 2.0,downfall: 0.0,water: 0x3F76E4,grass: 0x90814D,foliage: 0x9E814D,dryFoliage: -1,modifier: .none),
    ]
}
