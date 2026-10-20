// Regression coverage for quest-app/Assets/Scripts/World/GreedyMesher.cs at f0583fd
// and World/SectionPlan.cs at f63878e.
import Testing
@testable import TabletopCore

struct BoundaryTests {
    @Test func largestPaletteIndexStillMeshesInsideTheRegion() throws {
        var world = WorldModel()
        world.snapshotId = 1
        world.dims = [1, 1, 1]
        world.palette = [String](repeating: "minecraft:air", count: 65536)
        world.palette[65535] = "minecraft:stone"
        world.grid = try ChunkSnapshot.decodeRle([65535, 1], 1, 65536)
        var mesh = MeshData()
        GreedyMesher.build(world, .zero, &mesh)
        #expect(mesh.verts.count == 24 && mesh.opaque.count == 36)
        #expect(mesh.colors.allSatisfy { $0 == Color32(125, 125, 125) })
    }

    @Test func extremeOriginsCannotOverflowRekeyEligibility() {
        #expect(!SectionPlan.canRekey("world", [Int.min, 0, 0], [16, 16, 16],
                                    "world", [Int.max, 0, 0], [16, 16, 16]))
        #expect(!SectionPlan.canRekey("world", .zero, [Int.max, 16, 16],
                                    "world", [16, 0, 0], [Int.max, 16, 16]))
        let old = m1aWorld([1, 1, 1], origin: [Int.min, 0, 0]) { _, _, _ in 1 }
        let snapshot = ChunkSnapshot(snapshotId: 2, world: "world", origin: [Int.max, 0, 0],
                                     dims: [1, 1, 1], palette: old.palette, grid: [1])
        let plan = SectionPlan.compute(old, snapshot)
        #expect(!plan.rekey && plan.mesh == [.zero])
    }
}
