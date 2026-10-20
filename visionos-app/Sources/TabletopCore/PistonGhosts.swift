// Port of quest-app/Assets/Scripts/World/PistonGhosts.cs at f7d4a0f.
// One value recorder per update; no global or cross-world state.
public struct PistonGhosts: Sendable {
    private var old: [Int: UInt16] = [:]
    public init() {}
    public static func begin(_ w: WorldModel) -> PistonGhosts? {
        if !w.movingShown.isEmpty || w.palette.contains(where: isMoving) { return PistonGhosts() }
        return nil
    }
    public mutating func record(_ index: Int, _ id: UInt16) { if old[index] == nil { old[index] = id } }
    public func apply(_ w: inout WorldModel) {
        // Resolve all ghosts against the same post-update grid, before changing the display map.
        for index in old.keys {
            guard index >= 0 && index < w.grid.count else { continue }
            let now = w.state(w.grid[index])
            w.movingShown[index] = Self.isMoving(now) ? shown(w,index,now) : nil
        }
    }
    private func prev(_ w: WorldModel, _ i: Int) -> String { w.state(old[i] ?? w.grid[i]) }
    private func shown(_ w: WorldModel, _ c: Int, _ moving: String) -> String? {
        let props = Self.props(moving), facing = props["facing"], type = props["type"], d = Self.step(facing)
        let x = c%w.dims.x, z = c/w.dims.x%w.dims.z, y = c/(w.dims.x*w.dims.z), previous = prev(w,c)
        if Self.isBase(previous) { return previous }
        if w.inBounds(x-d.x,y-d.y,z-d.z) {
            let b = w.index(x-d.x,y-d.y,z-d.z), nowB = w.state(w.grid[b])
            if Self.isBase(nowB) {
                let bp = Self.props(nowB)
                if bp["extended"] == "true" && bp["facing"] != nil && bp["facing"] == facing {
                    return "minecraft:piston_head[facing=\(facing ?? ""),short=false,type=\(type == "sticky" ? "sticky" : "normal")]"
                }
            }
            if old[b] != nil && Self.movable(prev(w,b)) { return prev(w,b) }
        }
        if w.inBounds(x+d.x,y+d.y,z+d.z) {
            let f = w.index(x+d.x,y+d.y,z+d.z), p = prev(w,f)
            if old[f] != nil && Self.movable(p) && p != w.state(w.grid[f]) { return p }
        }
        return Self.isAir(previous) || Self.isMoving(previous) ? nil : previous
    }
    private static func props(_ state: String) -> [String: String] {
        guard let open = state.firstIndex(of: "["), let close = state[open...].firstIndex(of: "]") else { return [:] }
        var props: [String:String] = [:]
        for part in state[state.index(after: open)..<close].split(separator: ",") {
            let pair = part.split(separator: "=",maxSplits: 1)
            if pair.count == 2 { props[String(pair[0])] = String(pair[1]) }
        }
        return props
    }
    private static func step(_ facing: String?) -> SIMD3<Int> {
        switch facing {
        case "north": return SIMD3(0,0,-1)
        case "south": return SIMD3(0,0,1)
        case "west": return SIMD3(-1,0,0)
        case "east": return SIMD3(1,0,0)
        case "up": return SIMD3(0,1,0)
        default: return SIMD3(0,-1,0)
        }
    }
    public static func isMoving(_ s: String) -> Bool { BlockRules.path(s) == "moving_piston" }
    private static func isBase(_ s: String) -> Bool { ["piston","sticky_piston"].contains(BlockRules.path(s)) }
    private static func isAir(_ s: String) -> Bool { ["air","cave_air","void_air"].contains(BlockRules.path(s)) }
    private static func movable(_ s: String) -> Bool {
        !isAir(s) && !isBase(s) && !["moving_piston","piston_head","water","lava"].contains(BlockRules.path(s))
    }
}
