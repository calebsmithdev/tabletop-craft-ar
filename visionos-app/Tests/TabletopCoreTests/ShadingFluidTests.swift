// Ports quest-app/Tests~/Program.cs (LightAndBiomeTests), WaterTests.cs, EyeTests.cs,
// RenderTests.cs (Pistons) and LivingTests.cs (lighting) at f7d4a0f.
import Foundation
import Testing
@testable import TabletopCore

private func sfWorld(_ dims: SIMD3<Int>, _ palette: [String] = ["minecraft:air","minecraft:stone"], _ fill: (Int,Int,Int) -> Int) -> WorldModel {
    var grid = [UInt16](repeating: 0,count: dims.x*dims.y*dims.z)
    for y in 0..<dims.y { for z in 0..<dims.z { for x in 0..<dims.x { grid[(y*dims.z+z)*dims.x+x] = UInt16(fill(x,y,z)) } } }
    var w = WorldModel()
    w.applySnapshot(ChunkSnapshot(snapshotId: 1,world: "synthetic",dims: dims,palette: palette,grid: grid))
    return w
}
private func sfFloor(_ walls: [SIMD3<Int>] = []) -> WorldModel {
    var w = sfWorld(SIMD3(3,4,3)) { x,y,z in y == 0 || walls.contains(SIMD3(x,y,z)) ? 1 : 0 }
    w.light = w.grid.map { $0 == 0 ? 240 : 0 }; return w
}
private struct SFFaces: IFaceSource {
    func face(_ state: String, _ dir: Int) -> FaceKey {
        let layer: Int
        switch state {
        case FluidRules.waterState: layer = 1
        case FluidRules.lavaState: layer = 2
        case FluidRules.waterFlowState: layer = 3
        case FluidRules.overlayState: layer = 4
        case FluidRules.lavaFlowState: layer = 5
        default: layer = 0
        }
        var k = FaceKey(layer: layer,color: BlockRules.flatColor(state))
        if layer == 3 || layer == 5 { k.random = FluidRules.quadTable }; return k
    }
}
private func sfFluid(_ w: WorldModel, _ section: SIMD3<Int> = .zero) -> MeshData {
    var m = MeshData(); FluidMesher.build(w,section,SFFaces(),&m); return m
}
private func sfFronts(_ m: MeshData, layer: Float? = nil) -> [Int] {
    let inside = Set(m.waterBack)
    return stride(from: 0,to: m.verts.count,by: 4).filter { !inside.contains($0) && (layer == nil || m.uvs[$0].z == layer!) }
}
private func sfTop(_ m: MeshData, _ q: Int) -> Bool {
    let a = m.verts[q], b = m.verts[q+1], c = m.verts[q+2]
    return !(a.x == b.x && b.x == c.x) && !(a.z == b.z && b.z == c.z)
}

@Suite struct ShadingFluidTests {
    @Test func lightmapReferenceAndValueIsolation() {
        let ar = BlockShading(), vanilla = BlockShading(minLight: -1), normal = BlockShading(brightness: 0.5,minLight: -1)
        #expect(abs(ar.lightmap(0,0).y-0.2) < 1e-6)
        #expect(abs(vanilla.lightmap(0,0).y-0.148) < 0.001)
        #expect(abs(normal.lightmap(0,0).y-0.094) < 0.001)
        #expect(ar.lightmap(15,0) == SIMD3<Float>(repeating: 1))
        #expect(ar.lightmap(0,10).x > ar.lightmap(0,10).z+0.05)
        #expect(abs(ar.lightmap(7.5,0).x-(ar.lightmap(7,0).x+ar.lightmap(8,0).x)/2) < 1e-6)
        for brightness: Float in [0,0.5,1] {
            let shading = BlockShading(brightness: brightness,minLight: -1)
            for sky in 0..<16 { for block in 0..<16 {
                // Independent double-precision GLSL reference from LivingTests.Vanilla.
                let bl = Double(block)/15, sl = Double(sky)/15
                let bb = bl/(4-3*bl)*1.4, sb = sl/(4-3*sl)
                let par = (2*bl-1)*(2*bl-1)
                var c = [1.0,216.0/255,140.0/255].map { tint in min(1,max(0,10.0/255+sb+(tint+(1-tint)*0.9*par)*bb)) }
                let top = c.max()!, inv = 1-top, scaled = 1-inv*inv*inv*inv
                if top > 0 { c = c.map { $0+($0*scaled/top-$0)*Double(brightness) } }
                let got = shading.rawLightmap(.noon,sky,block)
                for i in 0..<3 { #expect(abs(Double(got[i])-c[i]) < 1e-5) }
                #expect(shading.lightmapFor(.noon,sky,block) == shading.lightmap(Float(sky),Float(block)))
            } }
        }
        var w = sfFloor(), other = w
        w.shading = BlockShading(minLight: 0.7,smoothLighting: false)
        other.shading = ar
        #expect(other.shading.minLight == 0.2 && other.shading.smoothLighting)
        #expect(w.shading.minLight == 0.7 && !w.shading.smoothLighting)
    }
    @Test func lightCodesRoundBilerpAndSnorm() {
        #expect(LightCode.of(14.6,0.4) == 240)
        #expect(LightCode.of(-1,20) == 15)
        #expect(LightCode.of(7.5,7.49) == 135)
        for code in UInt8.min...UInt8.max {
            #expect(LightCode.fromSnorm(LightCode.toSnorm(code)) == (code == 241 ? 242 : code))
        }
        #expect(LightCode.fromSnorm(127) == 240)
        var q = Quad4(Color32(1,2,3)); q.l0 = 240; q.l1 = 240; q.l2 = 216; q.l3 = 216
        #expect(LightCode.bilerp(q,0.5,0.5) == 228)
        #expect(!q.same(0,2)); q.l2 = 240; #expect(q.same(0,2))
    }
    @Test func cornerAoHiddenDiagonalAndPartialFaces() {
        let key = FaceKey(layer: -1,color: Color32(200,200,200))
        let open = BlockShading.faceCorners(sfFloor(),key,1,0,1,3)
        #expect(open == Quad4(Color32(200,200,200)))
        let wall = sfFloor([SIMD3(2,1,1)])
        let q = BlockShading.faceCorners(wall,key,1,0,1,3)
        #expect(q.c0.r == 200 && q.c1.r == 200 && q.c2.r == 160 && q.c3.r == 160)
        #expect(BlockShading.faceCorners(sfFloor([SIMD3(2,1,2)]),key,1,0,1,3).c2.r == 160)
        let low = sfFloor([SIMD3(2,1,1),SIMD3(1,1,2)])
        #expect(BlockShading.faceCorners(low,key,1,0,1,3).c2.r == 120)
        let tall = sfFloor([SIMD3(2,1,1),SIMD3(1,1,2),SIMD3(2,2,1),SIMD3(1,2,2)])
        #expect(BlockShading.faceCorners(tall,key,1,0,1,3).c2.r == 80)
        let partial = BlockShading.quad(wall,key,SIMD3(1,0,1),3,SIMD3(1.5,1,1),SIMD3(1.5,1,2),SIMD3(2,1,2),SIMD3(2,1,1))
        #expect(partial.c0.r == 180 && partial.c2.r == 160)
        var flat = wall; flat.shading = BlockShading(smoothLighting: false)
        #expect(BlockShading.faceCorners(flat,key,1,0,1,3) == open)
        flat.light = nil; #expect(BlockShading.faceCorners(flat,key,1,0,1,3) == open)
    }
    @Test func cornerLightCodesCutawaysFlatAndEmission() {
        let key = FaceKey(color: Color32(200,200,200))
        var w = sfFloor()
        w.light = w.grid.map { $0 == 0 ? 13 : 0 }; w.light![w.index(1,1,1)] = 15
        let q = BlockShading.faceCorners(w,key,1,0,1,3), want = w.shading.lightmap(0,13.5)
        #expect(q.c0.r == UInt8(200*want.x+0.5) && q.c0.b == UInt8(200*want.z+0.5))
        #expect(q.l0 == LightCode.of(0,13.5))
        let (s,b) = BlockShading.smoothBlend(0,0,0,3,0,0,8,10)
        #expect(s == 8 && b == 8.25)
        let (ds,db) = BlockShading.smoothBlend(0,0,0,0,0,0,2,2)
        #expect(ds == 0.5 && db == 0.5)
        w.light = [UInt8](repeating: 0,count: w.grid.count)
        #expect(BlockShading.faceCorners(w,key,1,0,1,3).c0.r == 40)
        let cut = BlockShading.faceCorners(w,key,0,0,1,0)
        #expect(cut == Quad4(Color32(200,200,200)))
        let edge = BlockShading.faceCorners(w,key,0,0,1,3)
        #expect(edge.c0.r > edge.c2.r && edge.l0 > edge.l2)
        var full = key; full.shade = BakedModel.shadeFullBright
        #expect(BlockShading.faceCorners(w,full,1,0,1,3).l0 == 255)
        let emitted = BlockShading.faceCorners(w,key,1,0,1,3,floor: 9)
        #expect(emitted.l0 == LightCode.of(9,9))
        w.light![w.index(1,1,1)] = 0xA4
        let (_,code) = BlockShading.flat(w,key,SIMD3(1,1,1)); #expect(code == 0xA4)
        var model = BakedQuad(p0: SIMD3(0,1,0),p1: SIMD3(0,1,1),p2: SIMD3(1,1,1),p3: SIMD3(1,1,0),color: key.color,dir: 3)
        #expect(BlockShading.model(sfFloor([SIMD3(2,1,1)]),1,0,1,model).c2.r == 160)
        model.dir = -1; model.emission = 12
        #expect(BlockShading.model(w,1,1,1,model).l0 == LightCode.of(12,12))
    }
    @Test func biomeNoiseReferencesAndBlockTintRules() {
        let refs: [(Int,Int,Float)] = [(0,0,0),(1,1,0.09764258),(10,-7,0.4662441),(-100,250,0.07138351),(123,456,-0.11129549),(-2000,-3000,-0.55597997),(777,-31,0.7262097)]
        for (x,z,v) in refs { #expect(abs(SwampNoise.get(Double(x)*0.0225,Double(z)*0.0225)-v) < 1e-6) }
        let swamp = BiomeColors.info("minecraft:swamp")
        #expect(BiomeColors.colorOf(swamp,.grass,123,456) == 0x4C763C)
        #expect(BiomeColors.colorOf(swamp,.grass,10,-7) == 0x6A7039)
        #expect(BiomeColors.info("minecraft:plains",[0.1,0.1]).temperature == 0.8)
        #expect(BiomeColors.info("custom:plains",[0.95,0.9]).temperature == 0.95)
        #expect(BiomeColors.vanilla.count == 67)
        #expect(BiomeColors.blockTint("minecraft:water[level=4]").0 == .water)
        #expect(BiomeColors.blockTint("minecraft:spruce_leaves").1 == Color32(0x61,0x99,0x61))
        #expect(BiomeColors.blockTint("minecraft:redstone_wire[power=15]").1 == Color32(255,50,0))
        #expect(BiomeColors.blockTint("minecraft:pumpkin_stem[age=7]").1 == Color32(224,199,28))
        #expect(!BiomeColors.tinted("minecraft:cherry_leaves",0))
        #expect(!BiomeColors.tinted("minecraft:pink_petals",0) && BiomeColors.tinted("minecraft:pink_petals",1))
    }
    @Test func biomeBlendNegativeQuartsClampingAndMapIsolation() {
        var g = BiomeGrid(qDims: SIMD3(4,1,4),palette: ["minecraft:badlands","minecraft:cherry_grove"],cells: (0..<16).map { $0%4 < 2 ? 0 : 1 })
        let t = BiomeTints(g,origin: .zero,dims: SIMD3(16,4,16))
        #expect(t.tint(.grass,1,0,5) == 0x90814D && t.tint(.grass,14,0,5) == 0xB6DB61)
        #expect(t.tint(.grass,8,0,5) == 0xA6B759 && t.tint(.water,8,3,5) == 0x519DEA)
        g.cells = [UInt16](repeating: 1,count: 16)
        #expect(t.tint(.grass,-100,-100,5) == 0x90814D)
        let ng = BiomeGrid(qOrigin: SIMD3(-1,-1,-1),qDims: SIMD3(2,1,1),palette: ["minecraft:badlands","minecraft:cherry_grove"],cells: [0,1])
        let nt = BiomeTints(ng,origin: SIMD3(-4,-1,-1),dims: SIMD3(8,1,1))
        #expect(nt.tint(.grass,4,0,0) == 0xA6B759)
        var map = [Int](repeating: 0,count: 65536)
        let i = Int((1-Double(Float(0.8)))*255), j = Int((1-Double(Float(0.4))*Double(Float(0.8)))*255)
        map[j*256+i] = 0x123456
        let maps = BiomeColormaps(grass: map)
        map[j*256+i] = 0xABCDEF
        #expect(BiomeColors.lookup(maps.grass,0.8,0.4) == 0x123456)
        #expect(BiomeColors.lookup(nil,0.8,0.4) == -1)
        #expect(BiomeColormaps(grass: [1]).grass == nil)
        #expect(BiomeColors.lookup([Int](repeating: 0xAA112233,count: 65536),2,-1) == 0x112233)
        let swampGrid = BiomeGrid(qDims: SIMD3(1,1,1),palette: ["minecraft:swamp"],cells: [0])
        let st = BiomeTints(swampGrid,origin: SIMD3(120,0,453),dims: SIMD3(8,1,8))
        var r = 0, green = 0, b = 0
        for dz in -2...2 { for dx in -2...2 {
            let c = BiomeColors.colorOf(BiomeColors.info("minecraft:swamp"),.grass,123+dx,456+dz)
            r += (c >> 16)&255; green += (c >> 8)&255; b += c&255
        } }
        #expect(st.tint(.grass,3,0,3) == (r/25) << 16 | (green/25) << 8 | (b/25))
    }
    @Test func fluidRulesAndFaceOcclusion() {
        for state in ["minecraft:kelp[age=3]","minecraft:seagrass","minecraft:bubble_column","minecraft:oak_fence[waterlogged=true]"] { #expect(FluidRules.kind(state) == .water) }
        #expect(FluidRules.kind("minecraft:oak_fence[waterlogged=false]") == .none)
        #expect(FluidRules.amount(FluidRules.info("minecraft:water[level=3]")) == 5)
        #expect(FluidRules.amount(FluidRules.info("minecraft:water[level=9]")) == 8)
        #expect(FluidRules.intProp("minecraft:water[notlevel=7,level=3]","level") == 3)
        #expect(FluidRules.fullFaces("minecraft:oak_stairs[facing=east,half=bottom,shape=straight]",.model) == 6)
        #expect(FluidRules.fullFaces("minecraft:oak_slab[type=top]",.slab) == 8)
        #expect(FluidRules.faceState("minecraft:stone") == nil)
    }
    @Test func fluidGreedyHeightsCullingAndInsideFaces() {
        let water = "minecraft:water[level=0]"
        let one = sfFluid(sfWorld(SIMD3(1,1,1),["minecraft:air",water]) { _,_,_ in 1 })
        #expect(one.transparent.count == 36 && one.waterBack.count == 36 && one.verts.count == 48)
        #expect(Set(one.transparent).isDisjoint(with: Set(one.waterBack)))
        #expect(one.verts.map(\.y).max() == Float(8)/9)
        for i in stride(from: 0,to: one.transparent.count,by: 6) {
            let front = one.transparent[i], back = one.waterBack[i]
            #expect(one.verts[front] == one.verts[back])
            #expect(one.colors[front] == one.colors[back] && one.light[front] == one.light[back])
            #expect(one.waterBack[i+1] == back+2 && one.waterBack[i+2] == back+1)
        }
        let ocean = sfFluid(sfWorld(SIMD3(16,5,16),["minecraft:air",water]) { _,y,_ in y < 4 ? 1 : 0 })
        #expect(sfFronts(ocean).count == 10 && ocean.waterBack.count == ocean.transparent.count)
        #expect(ocean.verts.map(\.y).max() == 3+Float(8)/9)
        let kelp = sfFluid(sfWorld(SIMD3(2,1,1),["minecraft:air",water,"minecraft:kelp"]) { x,_,_ in x+1 })
        #expect(sfFronts(kelp).count == 6)
        #expect(!sfFronts(kelp).contains { q in (0..<4).allSatisfy { kelp.verts[q+$0].x == 1 } })
        let solid = sfFluid(sfWorld(SIMD3(2,1,1),["minecraft:air",water,"minecraft:stone"]) { x,_,_ in x+1 })
        #expect(sfFronts(solid).count == 5)
        for half in ["bottom","top"] {
            let slab = sfFluid(sfWorld(SIMD3(1,1,1),["minecraft:air","minecraft:oak_slab[type=\(half),waterlogged=true]"]) { _,_,_ in 1 })
            #expect(sfFronts(slab).count == 5)
        }
        let lava = sfFluid(sfWorld(SIMD3(1,1,1),["minecraft:air","minecraft:lava"]) { _,_,_ in 1 })
        #expect(lava.opaque.count == 36 && lava.transparent.isEmpty && lava.waterBack.isEmpty)
        let boundary = sfFluid(sfWorld(SIMD3(17,2,1),["minecraft:air",water]) { _,_,_ in 1 },SIMD3(1,0,0))
        #expect(boundary.verts.allSatisfy { $0.x >= 16 })
        #expect(!sfFronts(boundary).contains { q in (0..<4).allSatisfy { boundary.verts[q+$0].x == 16 } })
    }
    @Test func fluidFlowUvsExactBitsSlopesAndOverlay() throws {
        let flowLayer = Float(3+4096*64)
        // C# Mathf.PI = (float)Math.PI and trig = (float)Math.Sin/Cos/Atan2.
        let westUv = FluidMesher.flowUvs(-1,0)
        #expect(westUv[0].x.bitPattern == Float(0.5).bitPattern)
        #expect(westUv[0].y.bitPattern == Float(-1.5).bitPattern)
        for i in 0..<16 {
            let a = Float(i)*Float(Double.pi)/8, fx = Float(cos(Double(a))), fz = Float(sin(Double(a)))
            let uv = FluidMesher.flowUvs(fx,fz)
            #expect(abs(-(uv[3].y-uv[0].y)-fx) < 1e-4)
            #expect(abs(-(uv[1].y-uv[0].y)-fz) < 1e-4)
        }
        let pal = ["minecraft:air","minecraft:stone","minecraft:water[level=0]","minecraft:water[level=1]","minecraft:water[level=2]"]
        let stream = sfFluid(sfWorld(SIMD3(4,2,1),pal) { x,y,_ in y == 0 ? 1 : x < 3 ? 2+x : 0 })
        let tops = sfFronts(stream,layer: flowLayer).filter { sfTop(stream,$0) }
        #expect(tops.count == 3)
        for q in tops { #expect(-(stream.uvs[q+3].y-stream.uvs[q].y) > 0.99) }
        let sloped = tops.first(where: { stream.verts[$0].x == 1 })
        let q = try #require(sloped)
        #expect(stream.verts[q].y > stream.verts[q+3].y)
        let glass = sfFluid(sfWorld(SIMD3(3,1,1),["minecraft:air","minecraft:glass","minecraft:water"]) { x,_,_ in x == 1 ? 2 : x == 2 ? 1 : 0 })
        #expect(sfFronts(glass,layer: 4).count == 1 && sfFronts(glass,layer: flowLayer).count == 3)
        let drop = sfFluid(sfWorld(SIMD3(2,2,1),pal) { x,y,_ in x == 0 ? (y == 1 ? 2 : 1) : (y == 0 ? 2 : 0) })
        let dt = sfFronts(drop,layer: flowLayer).filter { sfTop(drop,$0) }
        #expect(dt.count == 1)
        for q in dt { #expect(-(drop.uvs[q+3].y-drop.uvs[q].y) > 0.99) }
    }
    @Test func fluidLightingBiomesAndPerWorldShapes() {
        var w = sfWorld(SIMD3(3,3,3),["minecraft:air","minecraft:water"]) { _,y,_ in y == 1 ? 1 : 0 }
        w.light = [UInt8](repeating: 0,count: w.grid.count)
        w.light![w.index(1,1,1)] = 0x43; w.light![w.index(1,2,1)] = 0xA1
        let (_,code) = BlockShading.fluid(w,Color32(255,255,255),1,1,1,3)
        #expect(code == 0xA3)
        #expect(BlockShading.fluid(w,Color32(255,255,255),0,1,1,0).1 == 240)
        let g = BiomeGrid(qDims: SIMD3(1,1,1),palette: ["minecraft:swamp"],cells: [0])
        w.tints = BiomeTints(g,origin: .zero,dims: w.dims)
        #expect(FluidMesher.waterColor(w,1,1,1,Color32(1,2,3,123)) == Color32(0x61,0x7B,0x64,123))
        let stairs = "minecraft:oak_stairs[facing=east,half=bottom,shape=straight,waterlogged=true]"
        var modelWorld = sfWorld(SIMD3(1,1,1),["minecraft:air",stairs]) { _,_,_ in 1 }
        #expect(sfFluid(modelWorld).verts.isEmpty)
        modelWorld.applyShapeOverrides([stairs:.model])
        #expect(sfFronts(sfFluid(modelWorld)).count == 4)
    }
    @Test func eyeSurfaceSlabsPowderAndOutside() {
        let w = sfWorld(SIMD3(1,2,1),["minecraft:air","minecraft:water"]) { _,_,_ in 1 }
        #expect(EyeMediumRules.at(w,SIMD3(0.5,0.95,0.5)) == .water)
        #expect(EyeMediumRules.at(w,SIMD3(0.5,1+Float(8)/9,0.5)) == .air)
        #expect(EyeMediumRules.at(w,SIMD3(0.5,1.85,0.5)) == .water)
        #expect(EyeMediumRules.at(w,SIMD3(-0.01,0.5,0.5)) == .air)
        let pal = ["minecraft:air","minecraft:oak_slab[type=bottom,waterlogged=true]","minecraft:oak_slab[type=top,waterlogged=true]","minecraft:powder_snow","minecraft:glass","minecraft:lava[level=7]"]
        let row = sfWorld(SIMD3(5,1,1),pal) { x,_,_ in x+1 }
        #expect(EyeMediumRules.at(row,SIMD3(0.5,0.25,0.5)) == .solid)
        #expect(EyeMediumRules.at(row,SIMD3(0.5,0.75,0.5)) == .water)
        #expect(EyeMediumRules.at(row,SIMD3(1.5,0.25,0.5)) == .water)
        #expect(EyeMediumRules.at(row,SIMD3(1.5,0.75,0.5)) == .solid)
        #expect(EyeMediumRules.at(row,SIMD3(2.5,0.5,0.5)) == .powderSnow)
        #expect(EyeMediumRules.at(row,SIMD3(3.5,0.5,0.5)) == .air)
        #expect(EyeMediumRules.at(row,SIMD3(4.5,0.1,0.5)) == .lava)
        #expect(EyeMediumRules.at(row,SIMD3(4.5,0.12,0.5)) == .air)
    }
    @Test func eyeHysteresisDwellFadeAndVision() {
        let w = sfWorld(SIMD3(5,5,5),["minecraft:air","minecraft:water"]) { _,y,_ in y < 4 ? 1 : 0 }
        var f = EyeMediumFilter()
        let under = SIMD3<Float>(2,3.5,2)
        f.update(w,under,0.01,0.02); #expect(f.medium == .air)
        f.update(w,under,0.01,0.02); #expect(f.medium == .air)
        f.update(w,under,0.01,0.02); #expect(f.medium == .water && f.changed)
        #expect(f.look.tintAlpha < 0.1)
        for i in 0..<20 { f.update(w,SIMD3(2,3+Float(8)/9+(i%2 == 0 ? 0.2 : -0.2),2),0.01,0.02); #expect(f.medium == .water && !f.changed) }
        #expect(abs(f.look.tintAlpha-0.45) < 1e-6)
        for _ in 0..<620 { f.update(w,under,0.01,0.05) }
        #expect(f.visionTicks == 600 && f.look.end == 96 && f.look.strength == 0.7)
        #expect(EyeMediumRules.waterVision(100) == 0.6)
        f.update(w,SIMD3(2,6,2),0.01,0.05); #expect(f.medium == .air && f.look.visible)
        for _ in 0..<5 { f.update(w,SIMD3(2,6,2),0.01,0.05) }
        #expect(!f.look.visible && f.visionTicks < 600)
        var instant = EyeMediumFilter(); instant.dwellSeconds = 0; instant.fadeSeconds = 0
        instant.update(w,under,0.01,0.01)
        #expect(instant.medium == .water && instant.look.tintAlpha == 0.45)
    }
    @Test func pistonPushPullRetractionFirstRecordAndCleanup() throws {
        let pal = ["minecraft:air","minecraft:piston[extended=false,facing=east]","minecraft:stone","minecraft:dirt","minecraft:piston[extended=true,facing=east]","minecraft:moving_piston[facing=east,type=normal]","minecraft:piston_head[facing=east,short=false,type=normal]","minecraft:sticky_piston[extended=true,facing=east]","minecraft:moving_piston[facing=east,type=sticky]","minecraft:piston_head[facing=east,short=false,type=sticky]"]
        func row(_ ids: [Int]) -> WorldModel { sfWorld(SIMD3(ids.count,1,1),pal) { x,_,_ in ids[x] } }
        func update(_ w: inout WorldModel, _ changes: [(Int,Int)]) throws {
            var recorder = try #require(PistonGhosts.begin(w))
            for (x,id) in changes { recorder.record(x,w.grid[x]); w.grid[x] = UInt16(id) }
            recorder.apply(&w)
        }
        var push = row([1,2,3,0,0]); let original = push
        try update(&push,[(0,4),(1,5),(2,5),(3,5)])
        #expect(push.movingShown == [1:pal[6],2:pal[2],3:pal[3]])
        #expect(original.movingShown.isEmpty && original.grid[1] == 2)
        try update(&push,[(1,6),(2,2),(3,3)]); #expect(push.movingShown.isEmpty)
        var retract = row([4,6,0]); try update(&retract,[(0,5),(1,0)])
        #expect(retract.movingShown == [0:pal[4]])
        try update(&retract,[(0,1)]); #expect(retract.movingShown.isEmpty)
        var sticky = row([7,9,2,0]); try update(&sticky,[(0,8),(1,5),(2,0)])
        #expect(sticky.movingShown == [0:pal[7],1:pal[2]])
        var duplicate = row([4]); var r = PistonGhosts(); r.record(0,4); r.record(0,0)
        duplicate.grid[0] = 5; r.apply(&duplicate); #expect(duplicate.movingShown[0] == pal[4])
        #expect(PistonGhosts.begin(sfWorld(SIMD3(1,1,1)) { _,_,_ in 0 }) == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"] != nil,"Set TABLETOP_CLIENT_JAR for the user's own 26.3 client jar"))
    func jarColormaps() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"])
        let zip = try ZipArchive(path: path)
        let maps = BiomeColormaps(grass: BiomeColormapLoader.read(zip,"grass"),foliage: BiomeColormapLoader.read(zip,"foliage"),dryFoliage: BiomeColormapLoader.read(zip,"dry_foliage"))
        #expect(BiomeColors.colorOf(BiomeColors.info("minecraft:plains"),.grass,0,0,colormaps: maps) == 0x91BD59)
        #expect(BiomeColors.colorOf(BiomeColors.info("minecraft:plains"),.foliage,0,0,colormaps: maps) == 0x77AB2F)
        #expect(BiomeColors.colorOf(BiomeColors.info("minecraft:plains"),.dryFoliage,0,0,colormaps: maps) == 0xA37546)
        #expect(BiomeColors.colorOf(BiomeColors.info("minecraft:dark_forest"),.grass,0,0,colormaps: maps) == 0x507A32)
    }
}
