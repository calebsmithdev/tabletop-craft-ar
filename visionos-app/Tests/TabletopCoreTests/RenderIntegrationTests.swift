import Testing
import TabletopCore
import TabletopRender
import simd

@Suite struct RenderIntegrationTests {
    @Test func boxClippingKeepsNearPlaneAndEitherEye() {
        let identity = matrix_identity_float4x4
        #expect(BatchVisibility.intersects(min: [-0.2, -0.2, 0.2], max: [0.2, 0.2, 0.8], clipFromTable: [identity]))
        #expect(!BatchVisibility.intersects(min: [2, 0, 0.2], max: [3, 1, 0.8], clipFromTable: [identity]))
        #expect(!BatchVisibility.intersects(min: [0, 0, -2], max: [1, 1, -1], clipFromTable: [identity]))
        #expect(BatchVisibility.intersects(min: [-0.2, -0.2, -1], max: [0.2, 0.2, 0.5], clipFromTable: [identity]))
        var shiftedEye = identity
        shiftedEye.columns.3.x = -2
        #expect(BatchVisibility.intersects(min: [2, 0, 0.2], max: [3, 1, 0.8], clipFromTable: [identity, shiftedEye]))
    }

    @Test func sceneRejectsLateResultsAndKeepsReopenSource() {
        let scene = BatchScene(), key = SIMD3<Int>(0, 0, 0)
        scene.reset(generation: 4)
        scene.publish(BatchUpload(generation: 4, key: key, data: BatchData.assemble([]), position: .zero, blockSize: 0.01, center: [16, 0, 16]))
        #expect(scene.snapshot().batches.count == 1)
        scene.reset(generation: 5)
        scene.publish(BatchUpload(generation: 4, key: key, data: BatchData.assemble([]), position: .zero, blockSize: 0.01, center: .zero))
        #expect(scene.snapshot().generation == 5)
        #expect(scene.snapshot().batches.isEmpty)
        scene.publish(BatchUpload(generation: 5, key: key, data: BatchData.assemble([]), position: [32, 0, 0], blockSize: 0.005, center: [32, 0, 32]))
        let retained = scene.snapshot()
        #expect(retained.batches[key]?.position == [32, 0, 0])
        #expect(retained.batches[key]?.center == [32, 0, 32])
    }

    @Test func cubeTrianglesFaceOutwardWithoutUnityMirror() {
        var world = WorldModel()
        world.load(ChunkSnapshot(snapshotId: 1, dims: [1, 1, 1], palette: ["minecraft:stone"], grid: [0]))
        var mesh = MeshData()
        GreedyMesher.build(world, .zero, &mesh)
        for i in stride(from: 0, to: mesh.opaque.count, by: 3) {
            let a = mesh.verts[mesh.opaque[i]], b = mesh.verts[mesh.opaque[i+1]], c = mesh.verts[mesh.opaque[i+2]]
            let normal = simd_cross(b-a, c-a)
            let fromCenter = (a+b+c)/3 - SIMD3<Float>(repeating: 0.5)
            #expect(simd_dot(normal, fromCenter) > 0)
        }
    }
}
