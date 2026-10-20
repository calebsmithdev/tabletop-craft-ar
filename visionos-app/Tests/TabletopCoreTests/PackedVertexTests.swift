// Port of quest-app/Tests~/RenderTests.cs (packed vertices and solid layers) at 281c614.
import Foundation
import Testing
@testable import TabletopCore

@Suite struct PackedVertexTests {
    @Test func packedRoundTripAndByteLayout() throws {
        var v = BatchVertex(pos: SIMD3(1.25,-2,0.5),color: Color32(201,100,50,200),uv: SIMD3(0.5,-1,Float(4096*3+9)))
        v.nx = 127; v.nw = 127
        let p = try #require(PackedVertex.tryPack(v))
        #expect(p.position == v.pos && p.uv == SIMD2(0.5,-1))
        #expect(p.light == 240 && p.dir == 0 && p.layer == 9 && p.table == 3)
        #expect(p.color == Color32(121,60,30,200))
        var bytes = Data(); p.appendBytes(to: &bytes)
        #expect(bytes.count == 20)
        #expect(Array(bytes.prefix(8)) == [80,0,128,255,32,0,240,0])
        #expect(Array(bytes.suffix(8)) == [0,2,0,252,9,0,3,0])
        v.pos.x = 512; #expect(PackedVertex.tryPack(v) == nil)
        v.pos.x = 0; v.uv.x = 32; #expect(PackedVertex.tryPack(v) == nil)
        v.uv.x = 0; v.uv.z = -1
        #expect(PackedVertex.tryPack(v)?.layer == -1)
        v.uv.z = 1e30; #expect(PackedVertex.tryPack(v) == nil)
        #expect(!SolidLayers.face(1e30,[0]))
        v.uv.z = -1e30; #expect(PackedVertex.tryPack(v)?.layer == -1)
    }
    @Test func directionsRoundingAndLightAlias() throws {
        for (normal,dir,shade) in [(SIMD3<Int8>(0,127,0),2,Float(1)),(SIMD3(0,-127,0),3,0.5),(SIMD3(0,0,127),4,0.8),(SIMD3(0,0,-127),5,0.8),(SIMD3(-127,0,0),1,0.6),(SIMD3(0,0,0),6,1)] {
            let result = PackedVertex.shade(normal.x,normal.y,normal.z)
            #expect(result.0 == shade && result.1 == dir)
        }
        var v = BatchVertex(pos: .zero,color: Color32(101,103,105),uv: .zero)
        v.ny = -127; v.nw = -128
        let p = try #require(PackedVertex.tryPack(v))
        #expect(p.light == 242 && p.color == Color32(50,52,52))
        v.pos = SIMD3(0.5/64,1.5/64,-0.5/64)
        let even = try #require(PackedVertex.tryPack(v))
        #expect(even.x == 0 && even.y == 2 && even.z == 0)
    }
    @Test func encodedTablesAndFourLayerSolidSplit() throws {
        #expect(SolidLayers.face(-1,[]))
        #expect(SolidLayers.face(4096*3+5,[5]))
        #expect(!SolidLayers.face(4096*64+5,[5,6,7]))
        #expect(SolidLayers.face(4096*64+5,[5,6,7,8]))
        #expect(!SolidLayers.face(-1,[],enabled: false))
        var m = MeshData()
        m.verts = [SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(1,1,0),SIMD3(0,1,0)]
        m.uvs = Array(repeating: SIMD3(0,0,Float(4096*64+5)),count: 4)
        m.colors = Array(repeating: Color32(255,255,255),count: 4)
        m.opaque = [0,1,2,0,2,3]
        #expect(SectionMesh.from(m,.zero,solidLayers: [5,6,7])?.solid == 0)
        let mesh = try #require(SectionMesh.from(m,.zero,solidLayers: [5,6,7,8]))
        #expect(mesh.solid == 6)
        #expect(BatchData.assemble([(mesh,.zero)]).packedBytes()?.count == 80)
    }
}
