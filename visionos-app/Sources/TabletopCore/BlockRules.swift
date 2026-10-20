// Port of quest-app/Assets/Scripts/World/BlockRules.cs at 08ba968.
// M1: asset-free classification. Pack overrides belong to an owning value in M3.
public enum BlockShape: UInt8, Sendable { case air, cube, transparentCube, cross, slab, fluid, model }

public struct Color32: Equatable, Hashable, Sendable {
    public var r, g, b, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public enum BlockRules {
    public static func name(_ state: String) -> String { String(state.prefix { $0 != "[" }) }
    public static func path(_ state: String) -> String {
        let n = name(state)
        return n.firstIndex(of: ":").map { String(n[n.index(after: $0)...]) } ?? n
    }
    public static func shape(_ state: String) -> BlockShape { classify(state) }
    public static func classify(_ state: String) -> BlockShape {
        let p = path(state)
        if ["air", "cave_air", "void_air", "barrier", "light", "structure_void"].contains(p) { return .air }
        if ["water", "lava", "bubble_column"].contains(p) { return .fluid }
        if p.hasSuffix("_slab") && !state.contains("type=double") { return .slab }
        if p.contains("glass") || p.hasSuffix("leaves") || p == "ice" || p.contains("slime_block") || p.contains("honey_block") { return .transparentCube }
        return isCross(p) || isNonCube(p) ? .cross : .cube
    }
    static func isCross(_ p: String) -> Bool {
        p.contains("sapling") || p.contains("flower") || ["short_grass", "tall_grass", "fern", "large_fern"].contains(p) ||
        p.contains("tulip") || ["dandelion", "poppy", "allium", "azure_bluet", "cornflower"].contains(p) || p.contains("orchid") ||
        p.contains("daisy") || p.contains("lily_of") || (p.contains("mushroom") && !p.contains("block")) || p == "dead_bush" ||
        ["wheat", "carrots", "potatoes", "beetroots", "vine", "roots", "_bush", "seagrass", "kelp"].contains(where: p.contains) ||
        p == "sugar_cane" || p == "cobweb"
    }
    static func isNonCube(_ p: String) -> Bool {
        ["torch", "rail", "sign", "button", "lever", "pressure_plate", "redstone_wire", "carpet", "ladder", "_pane", "fence", "door", "banner", "candle", "lantern", "chain"].contains(where: p.contains) || p.hasSuffix("_bars") || p.hasSuffix("_wall") || p == "snow"
    }
    public static func opaque(_ shape: BlockShape) -> Bool { shape == .cube }
    public static func flatColor(_ state: String) -> Color32 {
        let p = path(state)
        if p == "grass_block" { return Color32(96,160,64) }
        if p.contains("leaves") { return Color32(58,120,40) }
        if p == "water" { return Color32(52,92,220,170) }
        if p == "lava" { return Color32(230,100,20) }
        if p.contains("dirt") || p == "farmland" || p.contains("mud") { return Color32(134,96,67) }
        if p.contains("sand") { return Color32(219,207,163) }
        if p.contains("log") || p.contains("wood") || p.contains("stem") { return Color32(102,81,51) }
        if p.contains("planks") || (p.contains("stairs") && p.contains("oak")) { return Color32(162,130,78) }
        if p.contains("glass") { return Color32(200,230,240,90) }
        if p == "bedrock" { return Color32(60,60,60) }
        if p.contains("snow") { return Color32(245,250,250) }
        if p.contains("gold") { return Color32(246,208,61) }
        if p.contains("diamond") { return Color32(98,219,214) }
        if p.contains("iron") { return Color32(216,216,216) }
        if p.contains("brick") { return Color32(150,97,83) }
        if p.contains("torch") { return Color32(255,200,80) }
        for (name, color) in colors where p.contains(name) { return color }
        if ["stone", "ore", "andesite", "diorite", "granite", "deepslate", "cobble"].contains(where: p.contains) { return Color32(125,125,125) }
        // C# string.GetHashCode is process-randomized on .NET 8. Use specified FNV-1a
        // for unknown fallback colours; canonical parity fixtures use named colours.
        var h: UInt32 = 2166136261
        for c in p.utf8 { h = (h ^ UInt32(c)) &* 16777619 }
        return Color32(UInt8(80 + (h & 127)), UInt8(80 + ((h >> 8) & 127)), UInt8(80 + ((h >> 16) & 127)))
    }
    static let colors: [(String, Color32)] = [
        ("white",Color32(234,236,237)),("orange",Color32(240,118,19)),("magenta",Color32(189,68,179)),("light_blue",Color32(58,175,217)),
        ("yellow",Color32(248,198,39)),("lime",Color32(112,185,25)),("pink",Color32(237,141,172)),("light_gray",Color32(142,142,134)),
        ("gray",Color32(62,68,71)),("cyan",Color32(21,137,145)),("purple",Color32(121,42,172)),("blue",Color32(53,57,157)),
        ("brown",Color32(114,71,40)),("green",Color32(84,109,27)),("red",Color32(160,39,34)),("black",Color32(20,21,25))]
}
