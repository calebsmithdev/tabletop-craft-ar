// Port of quest-app/Tests~/RenderTests.cs model/random checks at f0583fd,
// with synthetic coverage for BlockModelBaker.cs at 455a58a.
import Foundation
import XCTest
@testable import TabletopCore

final class BlockModelTests: XCTestCase {
    private final class Assets: IModelAssets {
        var documents: [String: JSONObject] = [:]
        var reads: [String: Int] = [:]
        var calls: [(String,Bool,String)] = []
        var layers = ["block/stone": 0,"block/accent": 1,"block/glass": 2,"block/cutout": 3]
        func readJson(_ path: String) -> JSONObject? { reads[path,default: 0] += 1; return documents[path] }
        func texture(_ texture: String, _ tinted: Bool, _ state: String) -> FaceKey {
            calls.append((texture,tinted,state))
            return FaceKey(layer: layers[texture] ?? -1,color: Color32(255,255,255))
        }
        func alphaClass(_ layer: Int) -> Int { layer == 2 ? 2 : layer == 3 ? 1 : 0 }
        func state(_ name: String = "test", _ json: String = #"{"variants":{"":{"model":"block/test"}}}"#) throws {
            documents["assets/minecraft/blockstates/\(name).json"] = try PackJSON.parse(json)
        }
        func model(_ name: String = "test", _ value: JSONObject) { documents["assets/minecraft/models/block/\(name).json"] = value }
    }
    private func element(_ from: [JSONValue] = [0,0,0], _ to: [JSONValue] = [16,16,16], _ texture: String = "#all") -> JSONObject {
        var faces: JSONObject = [:]
        for name in BlockModelBaker.dirNames { faces[name] = .object(["texture": .string(texture),"cullface": .string(name)]) }
        return ["from": .array(from),"to": .array(to),"faces": .object(faces)]
    }
    private func cube(_ texture: String = "block/stone", _ el: JSONObject? = nil) -> JSONObject {
        ["textures": ["all": .string(texture)],"elements": .array([.object(el ?? element())])]
    }
    private func assets(_ model: JSONObject? = nil) throws -> Assets {
        let a = Assets(); try a.state(); a.model("test",model ?? cube()); return a
    }
    private func positions(_ q: BakedQuad) -> [SIMD3<Float>] { [q.p0,q.p1,q.p2,q.p3] }
    private func texcoords(_ q: BakedQuad) -> [SIMD3<Float>] { [q.t0,q.t1,q.t2,q.t3] }
    private func world(_ states: [String], _ ids: [UInt16], _ dims: SIMD3<Int>) -> WorldModel {
        var w = WorldModel(); w.snapshotId = 1; w.palette = states; w.grid = ids; w.dims = dims
        return w
    }

    func testVanillaRandomGoldensIncludingOverflowAndSignedNextLong() {
        // x,y,z,seed,plain4,plain16,plain5,partSeed,multi2,multi4,multi5,offsetXYZ
        let gold: [(Int,Int,Int,Int64,Int,Int,Int,Int64,Int,Int,Int,SIMD3<Float>)] = [
            (0,0,0,0,2,11,0,-4962768465676381896,0,1,3,SIMD3(-0.25,-0.200000003,-0.25)),
            (1,64,-1,51075559105168,2,9,0,-7656025847503286258,0,1,2,SIMD3(0.050000012,-0.186666667,-0.183333337)),
            (-37,70,123,127394479219720,0,2,1,3149645818009156871,0,1,2,SIMD3(0.050000012,-0.039999999,-0.183333337)),
            (1000,-12,-999,-89076087406270,2,10,0,-6563781731044010084,1,3,3,SIMD3(0.050000012,-0.039999999,0.116666675)),
            (12345,100,-54321,-94259506441571,1,5,0,6437769178289409417,0,1,2,SIMD3(-0.183333337,-0.200000003,-0.049999997)),
            (-30000000,319,29999999,-20892113470306,0,1,0,1896228282024270181,1,2,0,SIMD3(-0.25,-0.013333333,0.150000006))
        ]
        var xyz = BakedModel(); xyz.offsetKind = 2
        var plain = BakedModel(); plain.randomTotals = [4]
        var multi = BakedModel(); multi.randomTotals = [2,4]; multi.randomMultipart = true
        for g in gold {
            let seed = BlockRandom.seed(g.0,g.1,g.2)
            XCTAssertEqual(seed,g.3)
            var r = BlockRandom.JavaRandom(seed)
            XCTAssertEqual(r.nextInt(4),g.4); r.setSeed(seed)
            XCTAssertEqual(r.nextInt(16),g.5); r.setSeed(seed)
            XCTAssertEqual(r.nextInt(5),g.6); r.setSeed(seed)
            XCTAssertEqual(r.nextLong(),g.7)
            r.setSeed(g.7); XCTAssertEqual(r.nextInt(2),g.8)
            r.setSeed(g.7); XCTAssertEqual(r.nextInt(4),g.9)
            r.setSeed(g.7); XCTAssertEqual(r.nextInt(5),g.10)
            let off = BlockRandom.offset(xyz,g.0,g.2)
            for axis in 0..<3 { XCTAssertEqual(off[axis],g.11[axis],accuracy: 1e-8) }
            XCTAssertEqual(BlockRandom.pick(plain,g.0,g.1,g.2),g.4)
            XCTAssertEqual(BlockRandom.pick(multi,g.0,g.1,g.2),g.8*4+g.9)
        }
        // Non-power-of-two bound whose rejection test overflows a Java int.
        var rejection = BlockRandom.JavaRandom(0)
        XCTAssertEqual(rejection.nextInt(1073741825),516548029)
    }

    func testOffsetKindsAndVariantCopies() {
        var m = BakedModel(); m.variants = [BakedModel(),BakedModel()]
        BlockRandom.setOffset(&m,"small_dripleaf")
        XCTAssertEqual(m.offsetKind,2); XCTAssertEqual(m.maxVerticalOffset,0.1)
        XCTAssertTrue(m.variants!.allSatisfy { $0.offsetKind == 2 && $0.maxVerticalOffset == 0.1 })
        BlockRandom.setOffset(&m,"pointed_dripstone")
        XCTAssertEqual(m.maxHorizontalOffset,0.125); XCTAssertEqual(m.offsetKind,1)
        for x in -20..<20 { for z in -20..<20 {
            let off = BlockRandom.offset(m,x,z)
            XCTAssertEqual(off.y,0); XCTAssertLessThanOrEqual(abs(off.x),0.125); XCTAssertLessThanOrEqual(abs(off.z),0.125)
        } }
        XCTAssertEqual(BlockRandom.offset(BakedModel(),1,2),.zero)
    }

    func testUvCompositionRegistryCapacityPackingAndValueIsolation() {
        for a: UInt8 in 0..<8 { for b: UInt8 in 0..<8 {
            let (a00,a01,a10,a11) = RandomUv.matrix(a), (b00,b01,b10,b11) = RandomUv.matrix(b)
            let (r00,r01,r10,r11) = RandomUv.matrix(RandomUv.relative(a,b))
            XCTAssertEqual(r00*a00+r01*a10,b00); XCTAssertEqual(r00*a01+r01*a11,b01)
            XCTAssertEqual(r10*a00+r11*a10,b10); XCTAssertEqual(r10*a01+r11*a11,b11)
        } }
        var u: Float = 0.2, v: Float = 0.7
        RandomUv.apply(3,&u,&v); XCTAssertEqual(u,0.3,accuracy: 1e-6); XCTAssertEqual(v,0.2,accuracy: 1e-6)
        var registry = RandomUv()
        let codes: [UInt8] = [0,1,2,3,4,5,6,7,7,6,5,4,3,2,1,0]
        XCTAssertEqual(registry.register(codes),1); XCTAssertEqual(registry.register(codes),1)
        XCTAssertEqual(registry.version,1)
        let packed = registry.packed()
        XCTAssertEqual(packed.count,256); XCTAssertEqual(packed[4],16)
        for k in 0..<16 { XCTAssertEqual((Int(packed[k < 8 ? 5 : 6]) >> (3*(k%8)))&7,Int(codes[k])) }
        let snapshot = registry
        var detached = registry.table(1)!; detached[0] = 7
        XCTAssertEqual(registry.table(1),codes)
        for i in 0..<62 { XCTAssertNotEqual(registry.register([UInt8(i%8),UInt8(i/8)]),0) }
        XCTAssertEqual(registry.count,63); XCTAssertEqual(registry.register([7,7]),0)
        registry.reset(); XCTAssertEqual(registry.count,0); XCTAssertEqual(snapshot.count,1)
        XCTAssertNil(registry.table(0)); XCTAssertNil(registry.table(1))
        var k = FaceKey(layer: 17); k.random = 3
        let uv = CubeUv.greedy(1,.zero,k)
        XCTAssertEqual(uv.x.bitPattern,Float(-0.0).bitPattern)
        XCTAssertEqual(uv.z,Float(17+3*4096))
    }

    func testOrderedPackJsonAndVariantFirstMatchFallback() throws {
        let text = #"{"variants":{"z=1":{"model":"block/z"},"a=1":{"model":"block/a"}},"escaped\"key":{"z":1,"a":2},"a":[true,null,{"b":2,"a":1}],"duplicate":{},"duplicate":[2]}"#
        let parsed = try PackJSON.parse(text)
        XCTAssertEqual(PackJSON.keys(parsed.o("variants")!),["z=1","a=1"])
        XCTAssertEqual(PackJSON.keys(parsed.o("escaped\"key")!),["z","a"])
        XCTAssertEqual(PackJSON.keys(parsed.a("a")![2].objectValue!),["b","a"])
        XCTAssertEqual(parsed.a("duplicate"),[2])
        let a = Assets()
        try a.state("test",#"{"variants":{"z=1":{"model":"block/z"},"a=1":{"model":"block/a"}}}"#)
        a.model("z",cube("block/accent")); a.model("a",cube())
        let baker = BlockModelBaker(a)
        // Both match: source's first selector wins, even though it sorts last.
        XCTAssertEqual(baker.bake("minecraft:test[z=1,a=1]")?.cubeFaces?[0].layer,1)
        // No selectors match: source's first variant is the fallback.
        XCTAssertEqual(baker.bake("minecraft:test[other=2]")?.cubeFaces?[0].layer,1)
        XCTAssertThrowsError(try PackJSON.parse("[]"))
    }

    func testCubeCornerOrderAndFullCoverage() throws {
        let baker = BlockModelBaker(try assets())
        let m = try XCTUnwrap(baker.bake("minecraft:test"))
        XCTAssertTrue(m.fullCube); XCTAssertTrue(m.opaque); XCTAssertEqual(m.quads.count,6)
        XCTAssertEqual(m.cover,[UInt64](repeating: .max,count: 24))
        XCTAssertEqual(m.quads.map(\.dir),[0,1,2,3,4,5])
        XCTAssertEqual(positions(m.quads[0]),[SIMD3(0,1,0),SIMD3(0,0,0),SIMD3(0,0,1),SIMD3(0,1,1)])
        XCTAssertEqual(texcoords(m.quads[0]),[SIMD3(0,1,0),SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(1,1,0)])
        XCTAssertTrue(m.cubeFaces!.allSatisfy { $0.uvMap == 0 })
        for d in 0..<6 { XCTAssertTrue(m.covers(d,m.cullCells,d)) }
        var mesh = MeshData()
        BlockModelMesher.addQuad(&mesh,.zero,m.quads[0])
        XCTAssertEqual(mesh.opaque,[0,1,2,0,2,3]); XCTAssertEqual(mesh.verts,positions(m.quads[0]))
        XCTAssertEqual(mesh.uvs,texcoords(m.quads[0])); XCTAssertEqual(mesh.light,[240,240,240,240])
    }

    func testDefaultExplicitRotatedUvsAndUvLock() throws {
        let a = try assets(cube("block/stone",element([2,4,6],[12,14,16])))
        var m = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertEqual(m.quads[0].t0,SIMD3(0.375,0.875,0)); XCTAssertEqual(m.quads[0].t2,SIMD3(1,0.25,0))
        var el = element()
        el["faces"] = ["west": ["texture": "#all","uv": [2,3,10,13],"rotation": 90,"cullface": "west"]]
        a.model("test",cube("block/stone",el))
        m = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertEqual(m.quads[0].t0,SIMD3(0.125,0.1875,0)); XCTAssertEqual(m.quads[0].t1,SIMD3(0.625,0.1875,0))
        a.model("test",cube())
        try a.state("test",#"{"variants":{"":{"model":"block/test","y":90}}}"#)
        let rotated = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertEqual(rotated.quads.map(\.dir),[4,5,2,3,1,0])
        XCTAssertEqual(rotated.quads.map(\.cull),[4,5,2,3,1,0])
        try a.state("test",#"{"variants":{"":{"model":"block/test","y":90,"uvlock":true}}}"#)
        let locked = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertTrue(locked.cubeFaces!.allSatisfy { $0.uvMap == 0 })
        XCTAssertNotEqual(rotated.cubeFaces![3].uvMap,locked.cubeFaces![3].uvMap)
    }

    func testParentsTextureObjectsBareSlotsAoAndEmission() throws {
        let a = try assets()
        a.model("parent",cube())
        a.model("test",["parent": "block/parent","ambientocclusion": false,"textures": ["all": ["sprite": "block/accent","force_translucent": true]]])
        var m = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertEqual(m.shade,BakedModel.shadeFlat); XCTAssertFalse(m.opaque)
        XCTAssertTrue(m.quads.allSatisfy { $0.translucent && $0.t0.z == 1 })
        XCTAssertTrue(m.cubeFaces!.allSatisfy { $0.shade == BakedModel.shadeFlat })
        var el = element([0,0,0],[16,16,16],"all"); el["light_emission"] = 99
        a.model("test",cube("block/stone",el))
        m = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertTrue(m.quads.allSatisfy { $0.emission == 15 })
        try a.state("magma_block"); XCTAssertEqual(BlockModelBaker(a).bake("minecraft:magma_block")?.shade,BakedModel.shadeFullBright)
        try a.state("sculk_sensor"); XCTAssertEqual(BlockModelBaker(a).bake("minecraft:sculk_sensor[sculk_sensor_phase=active]")?.shade,BakedModel.shadeFullBright)
        // Parent cycles terminate at the same fixed depth; unresolved texture cycles do not emit.
        a.model("test",["parent": "block/test","textures": ["all": "#cycle","cycle": "#all"],"elements": .array([.object(el)])])
        XCTAssertEqual(BlockModelBaker(a).bake("minecraft:test")?.quads.count,0)
        XCTAssertLessThanOrEqual(a.reads["assets/minecraft/models/block/test.json",default: 0],20)
    }

    func testElementRotationsRescaleAndDegenerateFaces() throws {
        let a = try assets()
        var el = element()
        el["rotation"] = ["axis": "y","angle": 45,"origin": [8,8,8],"rescale": true]
        a.model("test",cube("block/stone",el))
        let m = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertFalse(m.fullCube); XCTAssertEqual(m.quads.map(\.dir),[-1,-1,2,3,-1,-1])
        XCTAssertEqual(m.quads[0].p0.x,-0.5,accuracy: 1e-6)
        el["rotation"] = ["x": 90,"y": 90,"z": 90,"origin": [8,8,8]]
        a.model("test",cube("block/stone",el))
        XCTAssertTrue(try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test")).quads.allSatisfy { $0.dir >= 0 })
        a.model("test",cube("block/stone",element([0,0,0],[0,0,0])))
        XCTAssertEqual(BlockModelBaker(a).bake("minecraft:test")?.quads.count,0)
        a.model("test",cube("block/stone",element([16,16,16],[0,0,0])))
        XCTAssertEqual(BlockModelBaker(a).bake("minecraft:test")?.quads.count,0)
        a.model("test",cube("block/cutout",element([16,16,16],[0,0,0])))
        XCTAssertEqual(BlockModelBaker(a).bake("minecraft:test")?.quads.count,6)
    }

    func testMultipartConditionsWeightedProductsAndComboLimit() throws {
        let p = BlockModelBaker.props("minecraft:test[north=true,level=2,mode=x]")
        XCTAssertTrue(BlockModelBaker.when(["AND": [["north": true],["OR": [["level": 2],["mode": "y"]]]]],p))
        XCTAssertTrue(BlockModelBaker.when(["mode": "!y|z"],p)); XCTAssertFalse(BlockModelBaker.when(["mode": "!x|z"],p))
        let a = try assets()
        a.model("accent",cube("block/accent"))
        try a.state("test",#"{"multipart":[{"when":{"north":"true"},"apply":[{"model":"block/test","weight":2},{"model":"block/accent"}]},{"apply":[{"model":"block/test"},{"model":"block/accent","weight":3}]}]}"#)
        let m = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test[north=true]"))
        XCTAssertEqual(m.randomTotals,[3,4]); XCTAssertEqual(m.variants?.count,12); XCTAssertTrue(m.randomMultipart)
        // Mixed-radix index is first-list digit * 4 + second-list digit.
        XCTAssertEqual(m.variants![0].quads[0].t0.z,0); XCTAssertEqual(m.variants![8].quads[0].t0.z,1)
        XCTAssertEqual(m.variants![0].quads[6].t0.z,0); XCTAssertEqual(m.variants![1].quads[6].t0.z,1)
        XCTAssertNil(m.variants![0].variants)
        try a.state("test",#"{"multipart":[{"apply":[{"model":"block/test"},{"model":"block/accent"}]},{"apply":[{"model":"block/test"},{"model":"block/accent"}]}]}"#)
        XCTAssertEqual(BlockModelBaker(a).bake("minecraft:test")?.variants?.count,2) // equal totals share the draw
        try a.state("test",#"{"variants":{" ":[{"model":"block/test","weight":64},{"model":"block/accent"}]}}"#)
        let limited = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertNil(limited.variants); XCTAssertTrue(limited.quads.allSatisfy { $0.t0.z == 0 })
    }

    func testCoverageIntersectionOverlayAndStateTint() throws {
        let a = try assets()
        a.model("half",cube("block/stone",element([0,0,0],[16,8,16])))
        try a.state("test",#"{"variants":{" ":[{"model":"block/test"},{"model":"block/half"}]}}"#)
        let m = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:test"))
        XCTAssertEqual(m.cover,m.variants![1].cover)
        XCTAssertEqual(m.cover[0],.max); XCTAssertEqual(m.cover[1],.max); XCTAssertEqual(m.cover[2],0)
        XCTAssertEqual(m.variants![0].cover,m.cover)
        XCTAssertFalse(m.covers(0,m.cullCells,0))
        var overlay = element(); overlay["faces"] = ["up": ["texture": "#overlay","cullface": "up","tintindex": 0]]
        a.model("test",["textures": ["all": "block/stone","overlay": "block/accent"],"elements": .array([.object(element()),.object(overlay)])])
        try a.state("grass_block")
        let grass = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:grass_block"))
        XCTAssertTrue(grass.fullCube); XCTAssertEqual(grass.cubeFaces![3].overlay,2); XCTAssertEqual(grass.cubeFaces![3].overlayTint,.grass)
        var tinted = element(); tinted["faces"] = ["up": ["texture": "#all","tintindex": 0]]
        a.model("test",cube("block/stone",tinted)); try a.state("redstone_wire")
        let red = try XCTUnwrap(BlockModelBaker(a).bake("minecraft:redstone_wire[power=15]"))
        XCTAssertEqual(red.quads[0].color,Color32(255,50,0)); XCTAssertFalse(red.quads[0].tinted)
    }

    func testPrepareSnapshotsRandomTablesAndAirFluidExclusions() throws {
        let a = try assets()
        try a.state("test",#"{"variants":{" ":[{"model":"block/test"},{"model":"block/test","y":90}]}}"#)
        let registry = BlockModels(a)
        var faces: [FaceKey] = []
        let baked = try XCTUnwrap(registry.prepare("minecraft:test",&faces))
        XCTAssertEqual(registry.shapeOverrides["minecraft:test"],.cube)
        XCTAssertNotEqual(faces[3].random,0); XCTAssertEqual(registry.randomUv.table(Int(faces[3].random))?.count,2)
        let source = registry.snapshot, uv = registry.randomUv
        var local = baked; local.quads[0].p0.x = 100; local.cubeFaces![0].layer = 50
        XCTAssertEqual(source.model("minecraft:test")?.quads[0].p0.x,baked.quads[0].p0.x)
        XCTAssertEqual(source.model("minecraft:test")?.cubeFaces?[0].layer,baked.cubeFaces?[0].layer)
        try a.state("air"); try a.state("water"); try a.state("glass")
        _ = registry.prepare("minecraft:air",&faces); _ = registry.prepare("minecraft:water",&faces); _ = registry.prepare("minecraft:glass",&faces)
        XCTAssertNil(registry.shapeOverrides["minecraft:air"]); XCTAssertNil(registry.shapeOverrides["minecraft:water"])
        XCTAssertEqual(registry.shapeOverrides["minecraft:glass"],.transparentCube)
        XCTAssertNil(source.model("minecraft:glass")); XCTAssertEqual(uv.count,registry.randomUv.count)
        XCTAssertNil(registry.prepare("minecraft:missing",&faces)); XCTAssertNil(registry.prepare("minecraft:missing",&faces))
        XCTAssertEqual(a.reads["assets/minecraft/blockstates/missing.json"],1)
    }

    func testPlaceholderEntityBoxesAndDisabledCodeDrawnModels() throws {
        let a = try assets(["textures": ["particle": "block/stone"]])
        for name in ["chest","bell","player_head","white_banner","decorated_pot","conduit","end_portal","oak_sign"] { try a.state(name) }
        let baker = BlockModelBaker(a)
        let chest = try XCTUnwrap(baker.bake("minecraft:chest[facing=north,type=single]"))
        XCTAssertEqual(chest.quads.count,6); XCTAssertEqual(chest.quads[0].p0,SIMD3(1.0/16,14.0/16,1.0/16))
        XCTAssertEqual(baker.bake("minecraft:bell")?.quads.count,12)
        XCTAssertEqual(baker.bake("minecraft:player_head[rotation=1]")?.quads.first?.color,Color32(190,140,110))
        XCTAssertEqual(baker.bake("minecraft:white_banner")?.quads.count,18)
        XCTAssertEqual(baker.bake("minecraft:decorated_pot")?.quads.count,12)
        baker.entityBoxes = false
        for name in ["chest","bell","player_head","white_banner","decorated_pot","conduit","end_portal"] {
            XCTAssertEqual(baker.bake("minecraft:"+name)?.quads.count,0,name)
        }
        // Signs have block-model geometry in modern jars, but old-pack placeholders remain wanted.
        XCTAssertEqual(baker.bake("minecraft:oak_sign")?.quads.count,12)
    }

    func testModelMesherOffsetCullingTranslucencyAndFrame() throws {
        let a = try assets(cube("block/stone",element([0,0,0],[16,8,16])))
        let baker = BlockModelBaker(a), model = try XCTUnwrap(baker.bake("minecraft:test"))
        var w = world(["minecraft:air","minecraft:test","minecraft:stone"],[1,2],SIMD3(2,1,1))
        w.applyShapeOverrides(["minecraft:test": .model])
        let models = BlockModelSource(["minecraft:test": model])
        var mesh = MeshData()
        BlockModelMesher.emit(&mesh,w,0,0,0,"minecraft:test",model,models)
        XCTAssertEqual(mesh.verts.count,20) // east neighbour opaque cube hides one face
        w.grid = [1,1]
        BlockModelMesher.emit(&mesh,w,1,0,0,"minecraft:test",model,models)
        XCTAssertEqual(mesh.verts.count,40) // half-model coverage hides the matching west face
        var plant = model; BlockRandom.setOffset(&plant,"poppy")
        w.origin = SIMD3(1000,-12,-999)
        var moved = MeshData(), plain = MeshData()
        BlockModelMesher.emit(&moved,w,0,0,0,"minecraft:test",plant,nil)
        BlockModelMesher.emit(&plain,w,0,0,0,"minecraft:test",model,nil)
        let off = BlockRandom.offset(plant,1000,-999)
        for i in plain.verts.indices { XCTAssertEqual(moved.verts[i],plain.verts[i]+off) }
        var q = model.quads[0]; q.translucent = true
        var one = MeshData(); BlockModelMesher.addQuad(&one,SIMD3(2,3,4),q)
        XCTAssertEqual(one.transparent,[0,1,2,0,2,3]); XCTAssertEqual(one.opaque,[])
        XCTAssertEqual(one.verts[0],q.p0+SIMD3(2,3,4))
    }

    func testOversizedCoordinatesAndNonfiniteTransformsRejectModelSafely() throws {
        let a = try assets()
        let baker = BlockModelBaker(a)
        // The west cullface reaches both coverage-mask conversion paths.
        for (index,height) in [1e20,1e300].enumerated() {
            let name = "oversized\(index)"
            a.model(name,cube("block/stone",element([0,0,0],[16,.number(height),16])))
            XCTAssertNil(baker.bakeModel("block/"+name,"minecraft:stone"))
        }
        var rotated = element()
        rotated["rotation"] = ["axis":"x","angle":45,"origin":.array([.number(1e300),0,0])]
        a.model("bad_rotation",cube("block/stone",rotated))
        XCTAssertNil(baker.bakeModel("block/bad_rotation","minecraft:stone"))
        var badUv = element()
        badUv["faces"] = ["west":["texture":"#all","cullface":"west","uv":.array([0,0,.number(1e300),16])]]
        a.model("bad_uv",cube("block/stone",badUv))
        XCTAssertNil(baker.bakeModel("block/bad_uv","minecraft:stone"))
        XCTAssertNotNil(baker.bakeModel("block/test","minecraft:stone"))
        try a.state("oversized",#"{"variants":{"":{"model":"block/oversized0"}}}"#)
        var faces = Array(repeating: FaceKey(layer: -1,color: Color32(125,125,125)),count: 6)
        let models = BlockModels(a)
        XCTAssertNil(models.prepare("minecraft:oversized",&faces))
        XCTAssertNil(models.shapeOverrides["minecraft:oversized"])
        XCTAssertTrue(faces.allSatisfy { $0.layer == -1 })
    }

    func testClientJarModelsAndRandomUvTables() throws {
        guard let path = ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"], !path.isEmpty else {
            throw XCTSkip("Set TABLETOP_CLIENT_JAR to the user's own client jar")
        }
        let atlas = try ResourcePackAtlas(path: path,referenceProfile: true)
        let states = ["minecraft:lily_pad","minecraft:fire[age=0,east=false,north=false,south=false,up=false,west=false]",
                      "minecraft:fire[age=0,east=true,north=true,south=false,up=false,west=false]",
                      "minecraft:chorus_plant[down=false,east=false,north=true,south=false,up=false,west=false]",
                      "minecraft:poppy","minecraft:short_grass","minecraft:stone","minecraft:dirt","minecraft:netherrack",
                      "minecraft:cobblestone","minecraft:grass_block[snowy=false]","minecraft:heavy_core[waterlogged=false]"]
        atlas.prewarm(states)
        let pack = atlas.baked()
        XCTAssertEqual(pack.model(states[0])?.variants?.count,4)
        XCTAssertEqual(pack.model(states[1])?.variants?.count,8); XCTAssertEqual(pack.model(states[1])?.randomMultipart,true)
        XCTAssertEqual(pack.model(states[2])?.variants?.count,4); XCTAssertEqual(pack.model(states[3])?.variants?.count,5)
        XCTAssertNil(pack.model("minecraft:poppy")?.variants); XCTAssertEqual(pack.model("minecraft:poppy")?.offsetKind,1)
        XCTAssertEqual(pack.model("minecraft:short_grass")?.offsetKind,2)
        XCTAssertTrue((0..<6).allSatisfy { pack.face("minecraft:stone",$0).random != 0 })
        XCTAssertNotEqual(pack.face("minecraft:dirt",3).random,0); XCTAssertEqual(pack.face("minecraft:dirt",0).random,0)
        XCTAssertEqual(pack.randomUv.table(Int(pack.face("minecraft:netherrack",3).random))?.count,16)
        XCTAssertTrue((0..<6).allSatisfy { pack.face("minecraft:cobblestone",$0).random == 0 })
        XCTAssertEqual(pack.model("minecraft:heavy_core[waterlogged=false]")?.quads.count,6)
        for state in ["minecraft:stone","minecraft:dirt","minecraft:netherrack","minecraft:grass_block[snowy=false]"] {
            let model = try XCTUnwrap(pack.model(state)), variants = try XCTUnwrap(model.variants)
            for d in 0..<6 {
                let codes = pack.randomUv.table(Int(model.cubeFaces![d].random))
                for (k,variant) in variants.enumerated() {
                    XCTAssertTrue(sameUv(variants[0],variant,d,codes?[k] ?? 0),"\(state), side \(d), variant \(k)")
                }
            }
        }
    }
    private func sameUv(_ a: BakedModel, _ b: BakedModel, _ d: Int, _ code: UInt8) -> Bool {
        guard let qa = a.quads.first(where: { $0.dir == d && $0.cull == d }), let qb = b.quads.first(where: { $0.dir == d && $0.cull == d }) else { return false }
        let pa = positions(qa), pb = positions(qb), ta = texcoords(qa), tb = texcoords(qb)
        let weights: [Float] = [0.55,0.25,0.15,0.05]
        var ua: Float = 0, va: Float = 0, ub: Float = 0, vb: Float = 0
        for i in 0..<4 {
            guard let j = pb.firstIndex(where: { abs($0.x-pa[i].x) < 1e-4 && abs($0.y-pa[i].y) < 1e-4 && abs($0.z-pa[i].z) < 1e-4 }) else { return false }
            ua += weights[i]*ta[i].x; va += weights[i]*ta[i].y; ub += weights[i]*tb[j].x; vb += weights[i]*tb[j].y
        }
        RandomUv.apply(code,&ua,&va)
        return abs((ua-floor(ua))-(ub-floor(ub))) < 1e-3 && abs((va-floor(va))-(vb-floor(vb))) < 1e-3
    }
}
