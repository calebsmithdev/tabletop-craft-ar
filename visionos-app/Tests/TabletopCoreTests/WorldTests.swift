// Ports quest-app/Tests~/Program.cs at 6017fc2 and NavTests.cs at fc1eadd.
// Includes their world/section cases and batch scheduling cases from MeshTests.cs at 281c614.
import Foundation
import Testing
@testable import TabletopCore

func m1aFixtureText(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("tools/fixtures/"+name),encoding: .utf8)
}
func m1aFixture(_ name: String) throws -> JSONObject {
    try #require(Json.parse(m1aFixtureText(name)).objectValue)
}
func m1aWorld(_ dims: Int3, origin: Int3 = .zero, palette: [String] = ["minecraft:air","minecraft:stone"], fill: (Int,Int,Int) -> Int) -> WorldModel {
    var grid = [UInt16](repeating: 0,count: dims.x*dims.y*dims.z)
    for y in 0..<dims.y { for z in 0..<dims.z { for x in 0..<dims.x { grid[(y*dims.z+z)*dims.x+x] = UInt16(fill(x+origin.x,y+origin.y,z+origin.z)) } } }
    var w = WorldModel(); w.applySnapshot(ChunkSnapshot(snapshotId: 1,world: "world",origin: origin,dims: dims,palette: palette,grid: grid)); return w
}
func m1aSnapshot(_ w: WorldModel, _ id: Int = 2) -> ChunkSnapshot {
    ChunkSnapshot(snapshotId: id,world: w.world,origin: w.origin,dims: w.dims,palette: w.palette,grid: w.grid,light: w.light,biomes: w.biomes)
}

@Suite struct WorldTests {
    @Test func updatesAndValueIsolation() throws {
        var world = m1aWorld(Int3(32,32,32)) { _,_,_ in 0 }
        let before = world
        world.dirtySections = []
        let update: JSONObject = ["snapshot_id":1,"palette_add":["minecraft:torch"],"changes":[[16,16,16,2],[-1,0,0,1],[0,0,0,-1],[0,0,0,99]]]
        let applied = world.applyBlockUpdate(update); #expect(applied)
        #expect(world.state(world.get(16,16,16)) == "minecraft:torch")
        #expect(world.dirtySections.count == 8)
        #expect(before.get(16,16,16) == 0 && before.palette.count == 2)
        #expect(world.get(-1,0,0) == UInt16.max)
        #expect(world.state(UInt16.max) == "minecraft:air")
        let staleApplied = world.applyBlockUpdate(["snapshot_id":0,"palette_add":["bad"],"changes":[]]); #expect(!staleApplied)
        #expect(world.palette.count == 3)
        world.light = [UInt8](repeating: 0,count: world.grid.count); world.dirtySections = []
        let lightApplied = world.applyBlockUpdate(["snapshot_id":1,"changes":[],"light":[[15,15,15,254]]]); #expect(lightApplied)
        #expect(world.light?[world.index(15,15,15)] == 254 && world.dirtySections.count == 8)
    }
    @Test func paletteEpoch() {
        var w = m1aWorld(Int3(1,1,1)) { _,_,_ in 0 }, table = PaletteTable<Int>()
        #expect(table.update(w) { $0.count }); #expect(table.computed == 2)
        let epoch = w.paletteEpoch
        var s = m1aSnapshot(w); s.palette.append("minecraft:glass"); w.applySnapshot(s)
        #expect(w.paletteEpoch == epoch); #expect(table.update(w) { $0.count }); #expect(table.computed == 3)
        s.palette.swapAt(0,1); w.applySnapshot(s)
        #expect(w.paletteEpoch == epoch+1); #expect(table.update(w) { $0.count }); #expect(table.computed == 6)
    }
    @Test func sectionsAndDeltaFixtures() throws {
        let full = try m1aFixture("chunk_snapshot_sections.json")
        let s = try SectionedSnapshot.assemble([full])
        var w = WorldModel(); w.applySnapshot(s)
        #expect(w.dims == Int3(32,16,16))
        #expect(w.state(w.get(3,7,9)) == "minecraft:stone")
        #expect(w.state(w.get(3,8,9)).hasPrefix("minecraft:grass_block"))
        #expect(w.state(w.get(3,9,9)) == "minecraft:air")
        var listed: [Int3] = []
        let d = try SectionedSnapshot.assemble([m1aFixture("chunk_snapshot_delta.json")],current: w,listed: &listed)
        var next = WorldModel(); next.applySnapshot(d)
        #expect(next.origin == Int3(16,60,0))
        #expect(next.state(next.get(4,3,15)) == "minecraft:stone")
        #expect(next.state(next.get(4,4,15)) == "minecraft:air")
        #expect(next.state(next.get(16,0,0)).hasPrefix("minecraft:oak_log"))
        #expect(next.state(next.get(31,0,0)).hasPrefix("minecraft:oak_log"))
        #expect(listed == [Int3(1,0,0)])
        let grow = try SectionedSnapshot.assemble([m1aFixture("chunk_snapshot_grow.json")],current: w)
        let shrink = try SectionedSnapshot.assemble([m1aFixture("chunk_snapshot_shrink.json")],current: w)
        #expect(grow.dims == Int3(64,16,16) && shrink.dims == Int3(16,16,16))
        for y in 0..<16 { for z in 0..<16 { for x in 0..<32 {
            #expect(grow.grid[(y*16+z)*64+x+16] == w.grid[(y*16+z)*32+x])
            if x < 16 { #expect(shrink.grid[(y*16+z)*16+x] == w.grid[(y*16+z)*32+x+16]) }
        } } }
    }
    @Test func strictSectionErrors() throws {
        let full = try m1aFixture("chunk_snapshot_sections.json"), delta = try m1aFixture("chunk_snapshot_delta.json")
        var w = WorldModel(); w.applySnapshot(try SectionedSnapshot.assemble([full]))
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([]) }
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([delta]) }
        var bad = full; bad["sections"] = .array(Array(full.a("sections")!.prefix(1)))
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad]) }
        bad = full; bad["sections"] = .array(full.a("sections")! + full.a("sections")!)
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad]) }
        for data: JSONValue in [[1,1000],[1,4097],[1,0],[-1,4096],[65536,4096],[1,4096.5],[1]] {
            bad = full; var sec = full.a("sections")![0].objectValue!; sec["data"] = data
            var secs = full.a("sections")!; secs[0] = .object(sec); bad["sections"] = .array(secs)
            #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad]) }
        }
        bad = delta; bad["sections"] = []
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad],current: w) }
        bad = delta; bad["base"] = ["snapshot_id":8,"shift":[8,0,0]]
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad],current: w) }
        bad = delta; bad["palette"] = ["minecraft:stone","minecraft:air"]
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad],current: w) }
        bad = full; bad["dims"] = [2147483647,2147483647,2147483647]
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad]) }
        bad = full; bad["origin"] = [0,0]
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad]) }
    }
    @Test func multipartAndAssembler() throws {
        let full = try m1aFixture("chunk_snapshot_sections.json")
        var a = full, b = full
        a["parts"] = 2; b["parts"] = 2; b["part"] = 1
        a["sections"] = .array([full.a("sections")![0]]); b["sections"] = .array([full.a("sections")![1]])
        var assembler = SnapshotAssembler(computeSectionPlan: true)
        try assembler.offer(a,WorldModel()); #expect(!assembler.busy && assembler.partsWaiting == 1)
        try assembler.offer(b,WorldModel())
        let pending = assembler.wait(); let r = try #require(pending)
        #expect(r.error == nil && r.parts == 2 && r.snapshot?.grid.count == 8192 && r.viewMargin == Int3(8,0,0) && r.plan?.rekey == false)
        #expect(assembler.wait() == nil)
        var inconsistent = b; inconsistent["world"] = "other"
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([a,inconsistent]) }
        inconsistent = b; inconsistent["palette"] = ["minecraft:air"]
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([a,inconsistent]) }
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([b,a]) }
        try assembler.offer(b,WorldModel()); #expect(assembler.wait()?.error != nil)
        try assembler.offer(a,WorldModel()); try assembler.offer(b,WorldModel())
        #expect(throws: (any Error).self) { try assembler.offer(full,WorldModel()) }
        _ = assembler.wait()
        try assembler.offer(m1aFixture("chunk_snapshot.json"),WorldModel())
        #expect(assembler.wait()?.snapshot?.dims == Int3(32,64,32))
    }
    @Test func lightAndBiomes() throws {
        let m = try m1aFixture("chunk_snapshot_sections_light.json"), s = try SectionedSnapshot.assemble([m])
        #expect(s.light?[0] == 0 && s.light?[256] == 240 && s.light?[1023] == 254)
        #expect(s.biomes?.palette.first == "minecraft:plains")
        var w = WorldModel(); w.applySnapshot(s)
        var keep = m; keep["snapshot_id"] = 4; keep["sections"] = []; keep["biomes"] = nil
        keep["base"] = ["snapshot_id":3,"shift":[0,0,0]]
        let kept = try SectionedSnapshot.assemble([keep],current: w)
        #expect(kept.light == s.light && kept.grid == s.grid)
        w.light = nil
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([keep],current: w) }
        var bad = m; bad["light"] = ["encoding":"rle_v1","in_sections":false]
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([bad]) }
        let biome = try #require(try BiomeGrid.from(["res":4,"q_origin":[-1,-1,-1],"q_dims":[2,1,1],"palette":["minecraft:plains","minecraft:swamp"],"encoding":"rle_palette_v1","data":[0,1,1,1]]))
        #expect(biome.at(-1,-1,-1) == 0 && biome.at(0,-1,-1) == 1 && biome.at(-100,-100,-100) == 0)
    }
    @Test func rekeyShiftGrowShrinkAndPaletteRemap() {
        let dims = Int3(48,16,32)
        let old = m1aWorld(dims) { _,y,_ in y < 5 ? 1 : 0 }
        var new = m1aWorld(dims,origin: Int3(16,0,0),palette: ["minecraft:stone","minecraft:air"]) { _,y,_ in y < 5 ? 0 : 1 }
        let p = SectionPlan.compute(old,m1aSnapshot(new))
        #expect(p.rekey && p.shiftSections == Int3(1,0,0) && p.kept == 4)
        #expect(p.mesh == Set([Int3(2,0,0),Int3(2,0,1)]))
        #expect(p.refresh == Set([Int3(1,0,0),Int3(1,0,1)]))
        let delta = SectionPlan.compute(old,m1aSnapshot(new),nil,p.mesh)
        #expect(delta.compared == 0 && delta.mesh == p.mesh)
        new.setLocal(4,15,3,0)
        let changed = SectionPlan.compute(old,m1aSnapshot(new),[Int3(2,0,1)])
        #expect(changed.mesh.contains(Int3(0,0,0)) && changed.mesh.contains(Int3(1,0,1)) && changed.kept == 2)
        let grown = m1aWorld(Int3(64,16,32)) { _,y,_ in y < 5 ? 1 : 0 }
        let grow = SectionPlan.compute(old,m1aSnapshot(grown))
        #expect(grow.rekey && grow.mesh.count == 2 && grow.kept == 6)
        let shrink = SectionPlan.compute(grown,m1aSnapshot(old))
        #expect(shrink.rekey && shrink.mesh.isEmpty && shrink.kept == 6 && shrink.refresh == Set([Int3(2,0,0),Int3(2,0,1)]))
        var odd = m1aSnapshot(old); odd.origin.x = 8
        #expect(!SectionPlan.compute(old,odd).rekey)
        odd.origin.x = 64; #expect(!SectionPlan.compute(old,odd).rekey)
        odd.origin = .zero; odd.world = "other"; #expect(!SectionPlan.compute(old,odd).rekey)
        let a = m1aWorld(Int3(40,16,16)) { _,y,_ in y < 5 ? 1 : 0 }
        let b = m1aWorld(Int3(40,16,16),origin: Int3(16,0,0)) { _,y,_ in y < 5 ? 1 : 0 }
        #expect(SectionPlan.compute(a,m1aSnapshot(b)).mesh == Set([Int3(1,0,0),Int3(2,0,0)]))
        var lit = m1aSnapshot(old); lit.light = [UInt8](repeating: 0,count: old.grid.count)
        var lw = WorldModel(); lw.applySnapshot(lit); lit.light![old.index(20,15,3)] = 254
        #expect(SectionPlan.compute(lw,lit).mesh == [Int3(1,0,0)])
    }
    @Test func batchLayoutAndScheduling() {
        let layout = BatchLayout(Int3(-17,60,-1),Int3(64,32,48),2)
        #expect(layout.keyOf(.zero) == Int3(-1,0,-1) && layout.sy == 3)
        let all = layout.allKeys(), sections = all.flatMap(layout.sectionsOf)
        #expect(Set(sections).count == 4*2*3 && sections.count == 24)
        let shifted = BatchLayout(Int3(-1,76,15),Int3(64,32,48),2)
        let section = Int3(1,1,1), newSection = section &- Int3(1,1,1)
        #expect(layout.keyOf(section) == shifted.keyOf(newSection))
        let key = layout.keyOf(section), offset = layout.offset(section,key,layout.sy), pos = layout.position(key,layout.sy)
        #expect(offset+pos == SIMD3<Float>(16,16,16))
        let after = BatchLayout(Int3(-17,60,-1),Int3(16,16,16),2)
        let r = BatchRules.afterRekey(layout,after,.zero,Set(sections),Set(all))
        #expect(r.gone == Set(all.filter { !after.covers($0) }))
        #expect(r.dirty == [layout.keyOf(.zero)])
        #expect(BatchRules.ready(false,0,0,1,true))
        #expect(!BatchRules.ready(true,0,2,1,true) && BatchRules.ready(true,0,2,1,false))
        let lay = BatchLayout(.zero,Int3(128,80,128),2)
        let vis = SectionBox(min: Int3(2,0,2),max: Int3(6,4,6)), scope = SectionBox(min: Int3(1,0,1),max: Int3(7,4,7)), keep = SectionBox(min: .zero,max: Int3(8,5,8))
        let k = lay.keyOf(Int3(0,0,3)), dirty: Set<Int3> = [Int3(0,1,3)]
        #expect(BatchRules.sectionsPending(lay,k,[],dirty,scope,keep,vis,false))
        #expect(!BatchRules.sectionsPending(lay,k,[],dirty,scope,keep,vis,true))
        #expect(!BatchRules.offScreen(lay,k,.all))
    }
}
