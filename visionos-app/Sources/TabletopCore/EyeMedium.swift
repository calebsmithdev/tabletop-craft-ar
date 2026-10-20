// Port of quest-app/Assets/Scripts/World/EyeMedium.cs at f7d4a0f.
// Pure block-space detection and value-owned filtering; no UI, clipping or shader state.
import Foundation

public enum EyeMedium: UInt8, Sendable { case air, water, lava, powderSnow, solid }
public struct Rgb: Sendable, Equatable {
    public var r, g, b: Float
    public init(_ r: Float = 0, _ g: Float = 0, _ b: Float = 0) { self.r = r; self.g = g; self.b = b }
    public static func hex(_ c: Int) -> Rgb { Rgb(Float((c >> 16)&255)/255,Float((c >> 8)&255)/255,Float(c&255)/255) }
    public static func * (_ a: Rgb, _ k: Float) -> Rgb { Rgb(a.r*k,a.g*k,a.b*k) }
    public static func lerp(_ a: Rgb, _ b: Rgb, _ t: Float) -> Rgb { Rgb(a.r+(b.r-a.r)*t,a.g+(b.g-a.g)*t,a.b+(b.b-a.b)*t) }
}
public struct EyeLook: Sendable, Equatable {
    public var fog = Rgb(), tint = Rgb()
    public var start: Float = 0, end: Float = 0, strength: Float = 0, tintAlpha: Float = 0
    public init(fog: Rgb = Rgb(), tint: Rgb = Rgb(), start: Float = 0, end: Float = 0, strength: Float = 0, tintAlpha: Float = 0) {
        self.fog = fog; self.tint = tint; self.start = start; self.end = end; self.strength = strength; self.tintAlpha = tintAlpha
    }
    public var visible: Bool { strength > 0 || tintAlpha > 0 }
    public static func lerp(_ a: EyeLook, _ b: EyeLook, _ t: Float) -> EyeLook {
        EyeLook(fog: Rgb.lerp(a.fog,b.fog,t),tint: Rgb.lerp(a.tint,b.tint,t),start: a.start+(b.start-a.start)*t,end: a.end+(b.end-a.end)*t,strength: a.strength+(b.strength-a.strength)*t,tintAlpha: a.tintAlpha+(b.tintAlpha-a.tintAlpha)*t)
    }
    public func off() -> EyeLook { var o = self; o.strength = 0; o.tintAlpha = 0; return o }
}

/// Sampling seam shared by the CPU reference world and the render-only neighborhood.
public protocol EyeMediumSampling {
    func medium(at position: SIMD3<Float>) -> EyeMedium
    func waterColor(at position: SIMD3<Float>) -> Rgb
}

extension EyeMediumSampling {
    public func near(_ position: SIMD3<Float>, _ medium: EyeMedium, _ margin: Float) -> Bool {
        if self.medium(at: position) == medium { return true }
        for axis in 0..<3 {
            var sample = position
            sample[axis] -= margin
            if self.medium(at: sample) == medium { return true }
            sample[axis] = position[axis] + margin
            if self.medium(at: sample) == medium { return true }
        }
        return false
    }
}

extension WorldModel: EyeMediumSampling {
    public func medium(at position: SIMD3<Float>) -> EyeMedium { EyeMediumRules.at(self, position) }
    public func waterColor(at position: SIMD3<Float>) -> Rgb { EyeMediumRules.waterColor(self, position) }
}

/// State strings are parsed only by the world owner, never on the compositor path.
public struct EyeMediumPalette: Sendable {
    fileprivate struct Entry: Sendable {
        enum Occupancy: UInt8, Sendable { case empty, full, bottom, top, powderSnow }
        var occupancy: Occupancy = .empty
        var fluid: UInt8 = 0
        init() {}
        init(_ state: String, _ shape: BlockShape) {
            let path = BlockRules.path(state), slab = path.hasSuffix("_slab")
            if path == "powder_snow" { occupancy = .powderSnow }
            else if shape == .cube || (slab && state.contains("type=double")) { occupancy = .full }
            else if slab { occupancy = state.contains("type=top") ? .top : .bottom }
            fluid = FluidRules.info(state)
        }
    }
    private var states: [String] = []
    private var shapes: [BlockShape] = []
    fileprivate var entries: [Entry] = []
    public private(set) var computed = 0
    public init() {}

    public mutating func update(_ world: WorldModel) {
        if entries.count > world.palette.count {
            entries.removeLast(entries.count - world.palette.count)
            states.removeLast(states.count - world.palette.count)
            shapes.removeLast(shapes.count - world.palette.count)
        }
        for index in world.palette.indices {
            let shape = world.shapeOf(UInt16(index)), state = world.palette[index]
            if index == entries.count {
                entries.append(Entry(state, shape)); states.append(state); shapes.append(shape)
                computed += 1
            } else if states[index] != state || shapes[index] != shape {
                entries[index] = Entry(state, shape); states[index] = state; shapes[index] = shape
                computed += 1
            }
        }
    }
    fileprivate func entry(_ id: UInt16) -> Entry { Int(id) < entries.count ? entries[Int(id)] : Entry() }
}

/// A bounded interior plus a one-cell sampling halo. Owns only resolved cells
/// and colors; no world, grid, palette or tints. Built on the session actor.
public struct EyeNeighborhood: Sendable, EyeMediumSampling {
    private struct Cell: Sendable {
        var occupancy: EyeMediumPalette.Entry.Occupancy = .empty
        var fluid: FluidKind = .none
        var surface: Float = 0
        var water = Rgb.hex(EyeMediumRules.defaultWaterColor)
    }
    public let loaded: Bool
    public let origin: SIMD3<Int>
    private let cells: [Cell]
    private let side: Int
    public let radius: Int

    public init(world: WorldModel, palette: EyeMediumPalette, head: SIMD3<Float>, radius: Int = 1) {
        loaded = world.loaded
        self.radius = min(16,max(1,radius))
        side = 2*self.radius + 3
        origin = (Self.block(head) ?? .zero) &- SIMD3(repeating: self.radius + 1)
        var cells = [Cell]()
        cells.reserveCapacity(side * side * side)
        for y in 0..<side { for z in 0..<side { for x in 0..<side {
            let p = origin &+ SIMD3(x,y,z)
            var cell = Cell()
            if world.loaded && world.inBounds(p.x,p.y,p.z) {
                let entry = palette.entry(world.get(p.x,p.y,p.z))
                cell.occupancy = entry.occupancy; cell.fluid = FluidRules.kind(entry.fluid)
                let above = world.get(p.x,p.y+1,p.z)
                let aboveFluid = above == .max ? FluidKind.none : FluidRules.kind(palette.entry(above).fluid)
                cell.surface = cell.fluid != .none && aboveFluid == cell.fluid ? 1 : FluidRules.height(entry.fluid)
            }
            // CPU reference clamps biome sampling even outside the world bounds.
            if world.loaded { cell.water = EyeMediumRules.waterColor(world, SIMD3(Float(p.x),Float(p.y),Float(p.z))) }
            cells.append(cell)
        } } }
        self.cells = cells
    }

    private static func block(_ p: SIMD3<Float>) -> SIMD3<Int>? {
        // Keep conversion and halo arithmetic bounded even for invalid tracking data.
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
              abs(p.x) < 1_000_000_000, abs(p.y) < 1_000_000_000, abs(p.z) < 1_000_000_000 else { return nil }
        return SIMD3(Int(floor(p.x)),Int(floor(p.y)),Int(floor(p.z)))
    }

    /// A frame may reuse the snapshot while the producer is busy only inside this
    /// interior, where every possible filter margin (at most one block) is known.
    public func contains(_ position: SIMD3<Float>) -> Bool {
        guard let block = Self.block(position) else { return false }
        let p = block &- origin
        return p.x >= 1 && p.y >= 1 && p.z >= 1 && p.x < side-1 && p.y < side-1 && p.z < side-1
    }
    private func cell(at position: SIMD3<Float>) -> Cell? {
        guard let block = Self.block(position) else { return nil }
        let p = block &- origin
        guard p.x >= 0 && p.y >= 0 && p.z >= 0 && p.x < side && p.y < side && p.z < side else { return nil }
        return cells[(p.y * side + p.z) * side + p.x]
    }
    public func medium(at position: SIMD3<Float>) -> EyeMedium {
        guard loaded, let cell = cell(at: position) else { return .air }
        let fraction = position.y - floor(position.y)
        switch cell.occupancy {
        case .powderSnow: return .powderSnow
        case .full: return .solid
        case .top where fraction >= 0.5: return .solid
        case .bottom where fraction < 0.5: return .solid
        default: break
        }
        guard position.y < floor(position.y) + cell.surface else { return .air }
        return cell.fluid == .water ? .water : cell.fluid == .lava ? .lava : .air
    }
    public func waterColor(at position: SIMD3<Float>) -> Rgb {
        cell(at: position)?.water ?? Rgb.hex(EyeMediumRules.defaultWaterColor)
    }
}

public enum EyeMediumRules {
    public static let defaultWaterColor = 0x3F76E4
    public static func at(_ w: WorldModel, _ p: SIMD3<Float>) -> EyeMedium {
        guard w.loaded else { return .air }
        let x = Int(floor(p.x)), y = Int(floor(p.y)), z = Int(floor(p.z))
        guard w.inBounds(x,y,z) else { return .air }
        let id = w.get(x,y,z), st = w.state(id), path = BlockRules.path(st)
        if path == "powder_snow" { return .powderSnow }
        let slab = path.hasSuffix("_slab")
        if w.shapeOf(id) == .cube || (slab && st.contains("type=double")) { return .solid }
        if slab && ((st.contains("type=top") && p.y-Float(y) >= 0.5) || (!st.contains("type=top") && p.y-Float(y) < 0.5)) { return .solid }
        let info = FluidRules.info(st), kind = FluidRules.kind(info)
        if kind == .none || !(p.y < Float(y)+surfaceHeight(w,x,y,z,info)) { return .air }
        return kind == .water ? .water : .lava
    }
    public static func surfaceHeight(_ w: WorldModel, _ x: Int, _ y: Int, _ z: Int, _ info: UInt8) -> Float {
        let above = w.get(x,y+1,z)
        if above != .max && FluidRules.kind(w.state(above)) == FluidRules.kind(info) { return 1 }
        return FluidRules.height(info)
    }
    public static func near(_ w: WorldModel, _ p: SIMD3<Float>, _ medium: EyeMedium, _ margin: Float) -> Bool {
        w.near(p, medium, margin)
    }
    public static func waterColor(_ w: WorldModel, _ p: SIMD3<Float>) -> Rgb {
        let c = w.tints?.tint(.water,Int(floor(p.x)),Int(floor(p.y)),Int(floor(p.z))) ?? -1
        return Rgb.hex(c < 0 ? defaultWaterColor : c)
    }
    public static func waterVision(_ ticks: Float) -> Float {
        if ticks >= 600 { return 1 }
        let a = min(1,max(0,ticks/100)), b = ticks < 100 ? 0 : (ticks-100)/500
        return a*0.6+b*0.4
    }
    public static func look(_ m: EyeMedium, _ water: Rgb, _ vision: Float) -> EyeLook {
        switch m {
        case .water:
            let fog = water*(0.6+0.4*vision)
            return EyeLook(fog: fog,tint: fog,start: 0,end: 96*max(0.5,vision),strength: 0.7,tintAlpha: 0.45)
        case .lava: return EyeLook(fog: Rgb(0.6,0.1,0),tint: Rgb(0.85,0.3,0.05),start: 0.25,end: 1,strength: 1,tintAlpha: 0.8)
        case .powderSnow: return EyeLook(fog: Rgb(0.623,0.734,0.785),tint: Rgb(0.92,0.95,0.98),start: 0,end: 2,strength: 1,tintAlpha: 0.7)
        case .solid: return EyeLook(fog: Rgb(0.03,0.03,0.03),tint: Rgb(),start: 0,end: 1.5,strength: 0.9,tintAlpha: 0.7)
        case .air: return EyeLook()
        }
    }
}
public struct EyeMediumFilter: Sendable {
    public var marginM: Float = 0.004, dwellSeconds: Float = 0.05, fadeSeconds: Float = 0.2
    public private(set) var medium: EyeMedium = .air
    public private(set) var changed = false
    public private(set) var look = EyeLook()
    public private(set) var visionTicks: Float = 0
    private var candidate: EyeMedium = .air
    private var candidateTime: Float = 0, fadeT: Float = 1
    private var from = EyeLook()
    public init() {}
    /// No sample means no observation. In particular, an outrun must not reset
    /// underwater dwell/fade, water-back visibility or accumulated water vision.
    @discardableResult public mutating func update(_ neighborhood: EyeNeighborhood?, at eye: SIMD3<Float>, blockSizeM: Float, dt: Float) -> EyeLook {
        guard let neighborhood, neighborhood.contains(eye) else { changed = false; return look }
        return update(neighborhood,eye,blockSizeM,dt)
    }
    @discardableResult public mutating func update<Sample: EyeMediumSampling>(_ w: Sample, _ eye: SIMD3<Float>, _ blockSizeM: Float, _ dt: Float) -> EyeLook {
        changed = false
        var raw = w.medium(at: eye)
        if raw != medium && medium != .air {
            let margin = min(1,max(0.05,marginM/max(1e-4,blockSizeM)))
            if w.near(eye,medium,margin) { raw = medium }
        }
        if raw == medium { candidateTime = 0 }
        else {
            if raw != candidate { candidate = raw; candidateTime = 0 }
            candidateTime += dt
            if candidateTime >= dwellSeconds {
                from = look; medium = raw; changed = true; fadeT = 0; candidateTime = 0
            }
        }
        visionTicks = medium == .water ? min(600,visionTicks+dt*20) : max(0,visionTicks-dt*200)
        let target = medium == .air ? from.off() : EyeMediumRules.look(medium,w.waterColor(at: eye),EyeMediumRules.waterVision(visionTicks))
        var f = from
        if !f.visible { f = target.off() }
        fadeT = fadeSeconds <= 0 ? 1 : min(1,fadeT+dt/fadeSeconds)
        let s = fadeT*fadeT*(3-2*fadeT)
        look = EyeLook.lerp(f,target,s)
        if fadeT >= 1 { from = look }
        return look
    }
}
