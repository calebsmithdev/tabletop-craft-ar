// Port of quest-app/Tests~/MeshTests.cs at 281c614, production-atlas adapter.
// Only hashes are retained. Real snapshot JSON and the user's jar remain outside the repository.
import Foundation
import Testing
@testable import TabletopCore

@Suite struct M3aIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"] != nil,
                  "Set TABLETOP_CLIENT_JAR to test cancelled vanilla atlas reuse"))
    func cancelledVanillaPrewarmResumesOnTheSameAtlas() async throws {
        actor Owner {
            let atlas: ResourcePackAtlas
            init(_ path: String) throws { atlas = try ResourcePackAtlas(path: path) }
            func cancelled() {
                withUnsafeCurrentTask { $0?.cancel() }
                #expect(throws: ResourcePackValidationError.cancelled) { try atlas.checkedPrewarm(["minecraft:oak_planks"]) }
                #expect(atlas.validationError == nil)
            }
            func resumed() throws -> BakedResourcePack {
                try atlas.checkedPrewarm(["minecraft:oak_planks"])
                return try atlas.checkedBaked()
            }
        }
        let owner = try Owner(#require(ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"]))
        await Task { await owner.cancelled() }.value
        let pack = try await owner.resumed()
        #expect(pack.face("minecraft:oak_planks",0).layer >= 0)
        #expect(pack.layers.count > 11 && !pack.animations.isEmpty)
    }

    @Test func existingAppFlatOverloadsRemainUnlitAndFluidFree() {
        var world = m1aWorld(Int3(3,2,1),palette: ["minecraft:air","minecraft:stone","minecraft:water[level=0]"]) { x,y,_ in y == 0 ? (x == 0 ? 1 : 2) : 0 }
        var baseline = MeshData(); GreedyMesher.build(world,.zero,&baseline)
        GreedyMesher.buildSpecials(world,.zero,&baseline)
        #expect(baseline.verts.count == 24 && baseline.transparent.isEmpty && baseline.waterBack.isEmpty)
        world.light = Array(repeating: 0,count: world.grid.count)
        var app = MeshData(); GreedyMesher.build(world,.zero,&app)
        GreedyMesher.buildSpecials(world,.zero,&app)
        #expect(MeshHash.exact(app) == MeshHash.exact(baseline))
        var textured = MeshData(); GreedyMesher.build(world,.zero,FlatFaceSource(),&textured)
        GreedyMesher.buildSpecials(world,.zero,FlatFaceSource(),&textured)
        #expect(textured.verts.count > app.verts.count && !textured.transparent.isEmpty)
        #expect(textured.colors.prefix(24) != app.colors[...])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"] != nil,
                  "Set TABLETOP_CLIENT_JAR to test immutable pack worker input"))
    func immutablePackMeshesOnWorkers() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"])
        let atlas = try ResourcePackAtlas(path: path)
        var world = m1aWorld(Int3(32,4,32),palette: ["minecraft:air","minecraft:stone","minecraft:grass_block","minecraft:oak_stairs[facing=east,half=bottom,shape=straight,waterlogged=false]","minecraft:water[level=0]"]) { x,y,z in
            y == 0 ? 1 : y == 1 && x < 8 && z < 8 ? 2 : x == 16 && z == 16 && y == 1 ? 3 : x > 22 && z > 22 && y == 1 ? 4 : 0
        }
        world.light = Array(repeating: 240,count: world.grid.count)
        atlas.prewarm(world.palette)
        let pack = atlas.baked(), oldLayerCount = pack.layers.count
        world.applyShapeOverrides(pack.shapeOverrides); world.setColormaps(pack.colormaps)
        // Owner can continue resolving states while old worker values stay independent.
        _ = atlas.face("minecraft:diamond_block",0)
        #expect(pack.layers.count == oldLayerCount)
        let input = world
        let sections = SectionPlan.keys(world.sectionCount)
        let mesh: @Sendable (Int3) -> String = { section in
            var m = MeshData(); GreedyMesher.build(input,section,pack,&m)
            GreedyMesher.buildSpecials(input,section,pack,&m)
            return MeshHash.exact(m)
        }
        let serial = sections.map(mesh)
        let parallel = await withTaskGroup(of: (Int,String).self) { group in
            for (index,section) in sections.enumerated() {
                group.addTask { (index,mesh(section)) }
            }
            var result = [String](repeating: "",count: sections.count)
            for await (index,hash) in group { result[index] = hash }
            return result
        }
        #expect(parallel == serial)
        #expect(pack.face("test:unprepared",0).layer == -1)
        #expect(pack.model("test:unprepared") == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"] != nil && ProcessInfo.processInfo.environment["TABLETOP_M3A_SNAPSHOTS"] != nil,
                  "Set TABLETOP_CLIENT_JAR and TABLETOP_M3A_SNAPSHOTS to replay the local real-scene hash goldens"))
    func realSnapshotsMatchProductionCSharpExactly() throws {
        let jar = try #require(ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"])
        let snapshots = try #require(ProcessInfo.processInfo.environment["TABLETOP_M3A_SNAPSHOTS"])
        // Captured Paper 26.3 mixed scenes, client jar 26.2; x,y,z section order.
        let cases: [(String,String,[String])] = [
            ("models","smooth",["54196a8a281ab257","10344b6d0b6c63d4","da59c06c9bbb2464","524d20f3edfe502b"]),
            ("models","flat",["858034665522cd81","c4612bd546229414","c24355db177936a0","524d20f3edfe502b"]),
            ("models","no-light",["8997748e1b391493","04985f9b3112b614","7b60716fb34636fc","524d20f3edfe502b"]),
            ("fluids","smooth",["54196a8a281ab257","7bb2f348363379da","7acb483115f266f4","a8ddced82992dd29"]),
            ("fluids","flat",["858034665522cd81","929563ecf8ccf254","d39703720a364e20","33d4457eb57427dc"]),
            ("fluids","no-light",["8997748e1b391493","b8afe851d5e7d79c","7b60716fb34636fc","590370bbe49ee9df"]),
            ("waterlogged","smooth",["47753792a34e3ab4","a378761aecd44240","68321e98dff8cb16","2679953a1faba420"]),
            ("waterlogged","flat",["5724a497c4daae66","fe24f3fc708a562a","e2258ea9d940d596","38830ec8bb6340ad"]),
            ("waterlogged","no-light",["1a799c341acf1f18","b425096d9b9e7b65","cdd79b3df4a82d0c","3e5abf8b2536eae3"])
        ]
        for (name,mode,expected) in cases {
            let url = URL(fileURLWithPath: snapshots).appendingPathComponent(name+".json")
            let object = try #require(try Json.parse(String(contentsOf: url,encoding: .utf8)).objectValue)
            var world = WorldModel(); world.applySnapshot(try ChunkSnapshot.from(object))
            #expect(world.light != nil && world.biomes != nil)
            if mode == "no-light" { world.light = nil; world.biomes = nil; world.tints = nil }
            world.shading = BlockShading(smoothLighting: mode != "flat")
            let atlas = try ResourcePackAtlas(path: jar); atlas.prewarm(world.palette)
            let pack = atlas.baked()
            let uploadHash = name == "waterlogged" ? "58b02046cf160540" : "eb3ec07de173d4a3"
            #expect(m3aUploadHash(pack) == uploadHash,"\(name) pixels, mips, animation frames/schedules, solid flags, colormaps and random tables")
            world.applyShapeOverrides(pack.shapeOverrides); world.setColormaps(pack.colormaps)
            var hashes: [String] = []
            let n = world.sectionCount
            for x in 0..<n.x { for y in 0..<n.y { for z in 0..<n.z {
                var m = MeshData(); let section = Int3(x,y,z)
                GreedyMesher.build(world,section,pack,&m); GreedyMesher.buildSpecials(world,section,pack,&m)
                hashes.append(MeshHash.exact(m))
            } } }
            #expect(hashes == expected,"\(name) \(mode)")
        }
    }
}

/// FNV-1a over upload-facing CPU data, matched to the unchanged C# atlas through
/// the out-of-tree adapter: pixels, every mip/frame, schedules, flags and tables.
private func m3aUploadHash(_ pack: BakedResourcePack) -> String {
    var hash: UInt64 = 14695981039346656037
    func byte(_ value: UInt8) { hash = (hash ^ UInt64(value)) &* 1099511628211 }
    func integer(_ value: Int) {
        let v = UInt32(truncatingIfNeeded: value)
        for i in 0..<4 { byte(UInt8(truncatingIfNeeded: v >> (8*i))) }
    }
    func pixels(_ values: [Color32]) {
        integer(values.count)
        for c in values { byte(c.r); byte(c.g); byte(c.b); byte(c.a) }
    }
    func mips(_ values: [[Color32]]) { integer(values.count); for level in values { pixels(level) } }
    integer(pack.tileSize); integer(pack.layers.count)
    for i in pack.layers.indices { pixels(pack.layers[i]); mips(pack.mips[i]); integer(pack.solidLayers.contains(i) ? 1 : 0) }
    integer(pack.animations.count)
    for animation in pack.animations {
        let meta = animation.meta
        integer(animation.layer); integer(meta.frameWidth); integer(meta.frameHeight); integer(meta.columns)
        integer(meta.imageFrames); integer(meta.cycleTicks); integer(meta.interpolate ? 1 : 0)
        integer(meta.frames.count); for frame in meta.frames { integer(frame.index); integer(frame.time) }
        integer(animation.frames.count); for frame in animation.frames { pixels(frame) }
        integer(animation.frameMips.count); for frame in animation.frameMips { mips(frame) }
    }
    integer(pack.randomTables.count); for value in pack.randomTables { integer(Int(value.bitPattern)) }
    for map in [pack.colormaps.grass,pack.colormaps.foliage,pack.colormaps.dryFoliage] {
        integer(map?.count ?? 0); for color in map ?? [] { integer(color) }
    }
    return String(format: "%016llx",hash)
}
