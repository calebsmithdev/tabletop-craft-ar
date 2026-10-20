// Ported from quest-app/Assets/Scripts/World/AreaMath.cs @ 67bc875.
import Foundation

public struct MeshEstimate: Sendable, Equatable, CustomStringConvertible {
    public var quads: Int64
    public init(quads: Int64) { self.quads = quads }
    public var vertices: Int64 { quads * 4 }
    public var triangles: Int64 { quads * 2 }
    public var description: String { "~\(quads / 1000)k faces / ~\(vertices / 1000)k verts" }
}

public struct AreaMath: Sendable {
    public static let surfacePerColumn = 5.5
    public static let cavePerBlock = 0.04
    public static let surfaceBand = 96
    public static let defaultQuadBudget: Int64 = 250_000
    public static let minBlockM: Float = 0.001
    public static let maxBlockM: Float = 0.25
    public static let nonEmptyFraction = 0.5
    public static let defaultSectionBudget = 300
    // Owned by the caller rather than a process-global mutable static (Swift 6).
    public var lightFactor = 1.0
    public init() {}

    public static func lightFactorFor(_ serverLight: Bool, _ smooth: Bool) -> Double {
        !serverLight ? 1 : smooth ? 1.35 : 1.15
    }
    public static func fitBlockSize(_ tableW: Float, _ tableD: Float, _ dx: Int, _ dz: Int,
                                    _ margin: Float = 0.95) -> Float {
        guard dx > 0, dz > 0, tableW > 0, tableD > 0 else { return 0.01 }
        return max(minBlockM, min(maxBlockM, min(tableW / Float(dx), tableD / Float(dz)) * margin))
    }
    public func estimate(_ dx: Int, _ dy: Int, _ dz: Int) -> MeshEstimate {
        Self.estimate(dx, dy, dz, lightFactor: lightFactor)
    }
    public static func estimate(_ dx: Int, _ dy: Int, _ dz: Int, lightFactor: Double = 1) -> MeshEstimate {
        let cols = Double(dx) * Double(dz)
        let deep = Double(max(0, dy - surfaceBand))
        let surface = cols * surfacePerColumn * Double(min(dy, surfaceBand)) / Double(surfaceBand)
        return MeshEstimate(quads: Int64(ceil((surface + cols * deep * cavePerBlock) * lightFactor)))
    }
    public static func overBudget(_ e: MeshEstimate, _ budget: Int64, _ overridden: Bool) -> Bool {
        !overridden && e.quads > budget
    }
    public static func sections(_ dx: Int, _ dy: Int, _ dz: Int) -> Int64 {
        Int64((dx + 15) / 16) * Int64((dy + 15) / 16) * Int64((dz + 15) / 16)
    }
    public static func estimateSections(_ dx: Int, _ dy: Int, _ dz: Int) -> Int64 {
        Int64(ceil(Double(sections(dx, dy, dz)) * nonEmptyFraction))
    }
    // BatchRules.Columns defaults to 2; the caller passes its current batch configuration.
    public static func estimateMeshes(_ dx: Int, _ dy: Int, _ dz: Int, columns: Int = 2) -> Int64 {
        let c = max(1, columns)
        let bx = ((dx + 15) / 16 + c - 1) / c + 1
        let bz = ((dz + 15) / 16 + c - 1) / c + 1
        return dy <= 0 ? 0 : Int64(bx) * Int64(bz)
    }
    public static func clampToCaps(_ dx: Int, _ dy: Int, _ dz: Int, _ maxX: Int, _ maxY: Int,
                                   _ maxZ: Int, _ maxBlocks: Int64) -> (Int, Int, Int) {
        let x = max(1, min(dx, maxX)), z = max(1, min(dz, maxZ))
        var y = max(1, min(dy, maxY))
        while Int64(x) * Int64(y) * Int64(z) > maxBlocks && y > 1 { y -= 1 }
        return (x, y, z)
    }
}
