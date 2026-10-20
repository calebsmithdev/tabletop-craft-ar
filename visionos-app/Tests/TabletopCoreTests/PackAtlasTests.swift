// Synthetic ports of Tests~/RenderTests.cs (mips), WaterTests.cs (animation), and PngDecoder.cs
// at f7d4a0f4536791c0d46ea296d45c1794ffd755e4. No game-derived fixtures.
import Foundation
import Testing
import zlib
@testable import TabletopCore

@Suite struct PackAtlasTests {
    @Test func linearLightMipsAndSolidification() {
        let checker = (0..<256).map { i in (i%16+i/16)%2 == 0 ? Color32(0,0,0) : Color32(255,255,255) }
        let chain = TextureMips.chain(checker,16)
        #expect(TextureMips.levels(16) == 5)
        #expect(chain.map(\.count) == [256,64,16,4,1])
        #expect(chain[1][0] == Color32(188,188,188))
        #expect(chain[4][0].a == 255)
        var hole = [Color32](repeating: Color32(0,0,0,0),count: 16)
        hole[5] = Color32(200,10,10)
        let solid = TextureMips.solidify(hole,4)
        #expect(solid.allSatisfy { $0.r == 200 && $0.g == 10 })
        #expect(solid.filter { $0.a == 255 }.count == 1)
        #expect(hole[0] == Color32(0,0,0,0))
        #expect(TextureMips.bytes(16,false) == 1024)
        #expect(TextureMips.bytes(16,true) == 1364)
        #expect(TextureMips.coverage([Color32(0,0,0)],1,0.3,1).isNaN)
    }

    @Test func cutoutCoverageAndTieOrder() {
        // A synthetic disconnected plant silhouette, with no game texture data.
        let px = (0..<256).map { i in
            let x = i%16, y = i/16
            return Color32(35,180,70,(x == 7 || y == 6 || (x > 2 && x < 12 && y > 8 && y < 13)) ? 255 : 0)
        }
        let kept = TextureMips.chain(px,16), target = TextureMips.coverage(px,16,0.3,1)
        var naive = TextureMips.solidify(px,16), size = 16, better = false
        for level in 1..<4 {
            naive = TextureMips.mean(naive,size); size >>= 1
            let before = abs(TextureMips.coverage(naive,size,0.3,1)-target)
            let after = abs(TextureMips.coverage(kept[level],size,0.3,1)-target)
            if after < before { better = true }
        }
        #expect(better)
        // BFS seeds are scanned in pixel order: equal distance uses the first seed.
        let tie = TextureMips.solidify([Color32(255,0,0),Color32(0,0,255),Color32(0,0,0,0),Color32(0,0,0,0)],2)
        #expect(tie[2] == Color32(255,0,0,0))
        #expect(tie[3] == Color32(0,0,255,0))
        #expect(TextureMips.chain([Color32](repeating: Color32(0,0,0,0),count: 4),2)[1][0].a == 6)
    }

    @Test func animationScheduleAndFrameGrid() throws {
        let a = try #require(TextureAnimation.parse(#"{"animation":{"frametime":3,"frames":[2,{"index":0,"time":5},7,1]}}"#,16,64))
        #expect(a.imageFrames == 4 && a.frames.count == 3 && a.frames[1].time == 5 && a.cycleTicks == 11)
        #expect([Int64(0),3,8,11,-1].map { a.at($0).frame } == [2,0,1,2,1])
        #expect(TextureAnimation.parse(#"{"texture":{"mipmap_strategy":"mean"}}"#,16,16) == nil)
        #expect(TextureAnimation.parse(#"{"animation":{}}"#,16,16) == nil)
        #expect(TextureAnimation.parse(#"{"animation":{"frames":[0,0]}}"#,16,32) == nil)
        #expect(TextureAnimation.parse(#"{"animation":{"width":3}}"#,16,32) == nil)
        #expect(TextureAnimation.parse("{broken",16,32) == nil)
        let grid = try #require(TextureAnimation.parse(#"{"animation":{"width":8,"height":8}}"#,16,16))
        #expect(grid.imageFrames == 4 && grid.columns == 2 && grid.origin(3).x == 8 && grid.origin(3).y == 8)
        let blend = try #require(TextureAnimation.parse(#"{"animation":{"frametime":4,"interpolate":true}}"#,2,4))
        #expect(blend.at(2).blend == 0.5 && blend.at(2).next == 1)
        #expect(blend.at(-1).frame == 1 && blend.at(-1).blend == 0.75)
        let widthOnly = try #require(TextureAnimation.parse(#"{"animation":{"width":2}}"#,4,8))
        #expect(widthOnly.frameHeight == 8 && widthOnly.columns == 2)
    }

    @Test func pngAllFiltersAndBottomUpRows() throws {
        let rows: [[UInt8]] = (0..<5).map { y in (0..<12).map { x in UInt8((x*17+y*23)%256) } }
        let png = try atlasPNG(3,5,8,6,rows,filters: [0,1,2,3,4])
        let image = try #require(PngDecoder.decode(png))
        #expect(image.width == 3 && image.height == 5)
        for y in 0..<5 { for x in 0..<3 {
            let row = rows[4-y], i = x*4
            #expect(image.pixels[y*3+x] == Color32(row[i],row[i+1],row[i+2],row[i+3]))
        } }
        #expect(TextureAnimation.pngSize(png)?.width == 3)
        #expect(TextureAnimation.pngSize(Array(png.prefix(20))) == nil)
    }

    @Test func pngSampleFormatsAndTransparency() throws {
        let grey = try atlasPNG(4,1,1,0,[[0x50]],trns: [0,1])
        #expect(PngDecoder.decode(grey)?.pixels == [Color32(0,0,0),Color32(255,255,255,0),Color32(0,0,0),Color32(255,255,255,0)])
        let palette = try atlasPNG(4,1,2,3,[[0x1b]],palette: [10,20,30,40,50,60,70,80,90,100,110,120],trns: [0,128])
        #expect(PngDecoder.decode(palette)?.pixels == [Color32(10,20,30,0),Color32(40,50,60,128),Color32(70,80,90),Color32(100,110,120)])
        let rgb = try atlasPNG(1,1,8,2,[[10,20,30]],trns: [0,10,0,20,0,30])
        #expect(PngDecoder.decode(rgb)?.pixels == [Color32(10,20,30,0)])
        let ga = try atlasPNG(1,1,16,4,[[0x12,1,0xab,2]])
        #expect(PngDecoder.decode(ga)?.pixels == [Color32(18,18,18,171)])
        let rgba = try atlasPNG(1,1,16,6,[[10,1,20,2,30,3,40,4]])
        #expect(PngDecoder.decode(rgba)?.pixels == [Color32(10,20,30,40)])
        let g16 = try atlasPNG(1,1,16,0,[[10,1]],trns: [10,1])
        #expect(PngDecoder.decode(g16)?.pixels == [Color32(10,10,10,0)])
        let g4 = try atlasPNG(2,1,4,0,[[0x4f]])
        #expect(PngDecoder.decode(g4)?.pixels == [Color32(68,68,68),Color32(255,255,255)])
    }

    @Test func malformedPngFailsWithoutTrapping() throws {
        let valid = try atlasPNG(1,1,8,6,[[1,2,3,255]])
        for count in [0,4,8,24,32,valid.count-5] { #expect(PngDecoder.decode(Array(valid.prefix(count))) == nil) }
        var interlaced = valid; interlaced[28] = 1
        #expect(PngDecoder.decode(interlaced) == nil)
        var huge = valid; huge.replaceSubrange(16..<20,with: [0x7f,0xff,0xff,0xff])
        #expect(PngDecoder.decode(huge) == nil)
        let badFilter = try atlasPNG(1,1,8,6,[[1,2,3,255]],filters: [5])
        #expect(PngDecoder.decode(badFilter) == nil)
        var badLength = valid; badLength.replaceSubrange(8..<12,with: [0xff,0xff,0xff,0xff])
        #expect(PngDecoder.decode(badLength) == nil)
        let illegalDepth = try atlasPNG(1,1,1,6,[[0]])
        #expect(PngDecoder.decode(illegalDepth) == nil)
    }

    @Test func zipStoredDeflateDescriptorAndCrc() throws {
        let url = try atlasZip([("stored",Array("first".utf8),false),("deflated",Array(repeating: 42,count: 4096),true),("empty",[],true)],descriptor: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(path: url.path)
        #expect(zip.names == ["stored","deflated","empty"])
        #expect(try zip.read("stored") == Array("first".utf8))
        #expect(try zip.read("deflated") == Array(repeating: 42,count: 4096))
        #expect(try zip.read("empty") == [])
        #expect(try zip.read("missing") == nil)
        var bad = try Data(contentsOf: url); bad[30+"stored".utf8.count] ^= 1
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".zip")
        try bad.write(to: corrupt); defer { try? FileManager.default.removeItem(at: corrupt) }
        let invalid = try ZipArchive(path: corrupt.path)
        #expect(throws: ZipArchiveError.self) { _ = try invalid.read("stored") }
        let truncated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".zip")
        try Data(bad.prefix(25)).write(to: truncated); defer { try? FileManager.default.removeItem(at: truncated) }
        #expect(throws: ZipArchiveError.self) { _ = try ZipArchive(path: truncated.path) }
    }

    @Test func productionPrewarmFlowQuartersAndAllFrameOpacity() throws {
        var entries = try atlasFluidEntries()
        // A palette texture comes after all canonical fluid states.
        entries += [("assets/test/blockstates/cube.json",Array(#"{"variants":{"":{"model":"test:cube"}}}"#.utf8),false),
                    ("assets/test/models/cube.json",Array(atlasCube("test:palette").utf8),true),
                    ("assets/test/textures/palette.png",try atlasSolidPNG(2,Color32(80,90,100)),false)]
        let url = try atlasZip(entries); defer { try? FileManager.default.removeItem(at: url) }
        let atlas = try ResourcePackAtlas(path: url.path)
        atlas.prewarm(["test:cube"])
        let baked = atlas.baked()
        #expect(baked.tileSize == 2)
        #expect(baked.layerNames == ["test:water_still","test:lava_still",
                                    "minecraft:block/water_flow#0","minecraft:block/water_flow#1","minecraft:block/water_flow#2","minecraft:block/water_flow#3",
                                    "minecraft:block/lava_flow#0","minecraft:block/lava_flow#1","minecraft:block/lava_flow#2","minecraft:block/lava_flow#3",
                                    "minecraft:block/water_overlay","test:palette"])
        let flow = baked.face("minecraft:water[tabletop=flow]",4)
        #expect(flow.layer == 2 && flow.random == 64 && flow.tint == .water)
        #expect(baked.layers[2][0] == Color32(11,1,1))
        #expect(baked.layers[3][0] == Color32(21,1,1))
        #expect(baked.layers[4][0] == Color32(31,1,1))
        #expect(baked.layers[5][0] == Color32(41,1,1))
        #expect(baked.animations.count == 4)
        #expect(baked.solidLayers.contains(2))
        // Quarter 1 is opaque initially, but has one transparent pixel in the later frame.
        #expect(!baked.solidLayers.contains(3))
        #expect(baked.mips[2].map(\.count) == [4,1])
        #expect(baked.animations[0].frameMips.count == 2)
        #expect(baked.face("minecraft:water",0).color == Color32(63,118,228,200))
        #expect(baked.model("test:cube")?.fullCube == true)
        #expect(baked.shapeOverrides["test:cube"] == .cube)
        #expect(baked.face("unknown",0).layer == -1)
    }

    @Test func resolvePrecedesPrepareAndReferenceModeIsDistinct() throws {
        // The first element's west face resolves A. Its east face resolves B, then the
        // second element introduces C during Prepare. Reference mode skips Resolve.
        let model = #"{"textures":{"all":"test:a"},"elements":[{"from":[0,0,0],"to":[16,16,16],"faces":{"west":{"texture":"test:a"},"east":{"texture":"test:b"}}},{"from":[0,0,0],"to":[1,1,1],"faces":{"west":{"texture":"test:c"}}}]}"#
        let entries = [
            ("assets/test/blockstates/state.json",Array(#"{"variants":{"prop=first":{"model":"test:first"},"prop=second":{"model":"test:second"}}}"#.utf8),false),
            ("assets/test/models/first.json",Array(model.utf8),true),
            ("assets/test/models/second.json",Array(atlasCube("test:d").utf8),true),
            ("assets/test/textures/a.png",try atlasSolidPNG(2,Color32(1,2,3)),true),
            ("assets/test/textures/b.png",try atlasSolidPNG(2,Color32(4,5,6)),true),
            ("assets/test/textures/c.png",try atlasSolidPNG(2,Color32(7,8,9)),true),
            ("assets/test/textures/d.png",try atlasSolidPNG(2,Color32(10,11,12)),true)]
        let url = try atlasZip(entries); defer { try? FileManager.default.removeItem(at: url) }
        let production = try ResourcePackAtlas(path: url.path)
        production.prewarm(["test:state[prop=absent]"])
        #expect(production.baked().layerNames == ["test:a","test:b","test:c"])
        #expect(production.baked().faces.count == 6) // five canonical fluids plus the palette state
        // Alias normalization and no canonical fluid prewarm are PackAssets-specific.
        let reference = try ResourcePackAtlas(path: url.path,referenceProfile: true)
        reference.prewarm(["test:state[prop=second]"])
        #expect(reference.baked().faces.count == 1)
        #expect(reference.baked().layerNames == ["test:d"])
        let saved = reference.baked()
        _ = reference.texture("test:a",false,"test:state")
        #expect(saved.layerNames == ["test:d"] && reference.baked().layerNames == ["test:d","test:a"])
    }

    @Test func referenceTintAliasesAndColormaps() throws {
        let mapRows = (0..<256).map { y in (0..<256).flatMap { x in [UInt8(x),UInt8(y),UInt8(13),UInt8(255)] } }
        let url = try atlasZip([
            ("assets/minecraft/textures/colormap/grass.png",try atlasPNG(256,256,8,6,mapRows),true),
            ("assets/minecraft/textures/block/a.png",try atlasSolidPNG(2,Color32(1,2,3)),false)])
        defer { try? FileManager.default.removeItem(at: url) }
        let prod = try ResourcePackAtlas(path: url.path), reference = try ResourcePackAtlas(path: url.path,referenceProfile: true)
        #expect(prod.baked().colormaps.grass?[0] == 13)
        #expect(prod.baked().colormaps.grass?[65535] == 0xffff0d)
        #expect(reference.baked().colormaps.grass == nil)
        let r0 = reference.texture("block/a",true,"minecraft:oak_leaves")
        let r1 = reference.texture("minecraft:block/a",true,"minecraft:water")
        #expect(r0.layer == r1.layer && r0.color == Color32(124,189,107) && r1.color == Color32(124,189,107))
        #expect(prod.texture("block/a",true,"minecraft:oak_leaves").color == Color32(89,174,48))
        #expect(prod.texture("minecraft:block/a",false,"minecraft:water").color == Color32(63,118,228,200))
        #expect(prod.baked().layerNames.count == 2)
    }

    @Test func multipartResolutionAllocatesBeforeMatchingModel() throws {
        // Resolve reads the first multipart apply even when its condition fails.
        // Prepare selects the second apply. The production-only, unused layer must remain.
        let bs = #"{"multipart":[{"when":{"enabled":"true"},"apply":{"model":"test:unused"}},{"when":{"enabled":"false"},"apply":{"model":"test:selected"}}]}"#
        let url = try atlasZip([
            ("assets/test/blockstates/conditional.json",Array(bs.utf8),false),
            ("assets/test/models/unused.json",Array(atlasCube("test:unused").utf8),false),
            ("assets/test/models/selected.json",Array(atlasCube("test:selected").utf8),false),
            ("assets/test/textures/unused.png",try atlasSolidPNG(2,Color32(20,30,40)),true),
            ("assets/test/textures/selected.png",try atlasSolidPNG(2,Color32(50,60,70)),true)])
        defer { try? FileManager.default.removeItem(at: url) }
        let prod = try ResourcePackAtlas(path: url.path), reference = try ResourcePackAtlas(path: url.path,referenceProfile: true)
        prod.prewarm(["test:conditional[enabled=false]"])
        reference.prewarm(["test:conditional[enabled=false]"])
        #expect(prod.baked().layerNames == ["test:unused","test:selected"])
        #expect(reference.baked().layerNames == ["test:selected"])
        #expect(prod.baked().face("test:conditional[enabled=false]",0).layer == 1)
        #expect(reference.baked().face("test:conditional[enabled=false]",0).layer == 0)
    }

    @Test func cropAndInterpolationRetainCurrentAlpha() throws {
        let source = [Color32(30,0,0),Color32(40,0,0),Color32(10,0,0),Color32(20,0,0)]
        #expect(ResourcePackAtlas.crop(source,2,2,0,0,1,1,2) == Array(repeating: Color32(10,0,0),count: 4))
        let meta = try #require(TextureAnimation.parse(#"{"animation":{"frametime":4,"interpolate":true}}"#,1,2))
        let animation = ResourcePackAtlasAnimation(layer: 0,meta: meta,
            frames: [[Color32(0,10,20,25)],[Color32(255,110,220,200)]],
            frameMips: [[[Color32(0,10,20,25)]],[[Color32(255,110,220,200)]]])
        #expect(animation.mips(at: 2)[0][0] == Color32(127,59,119,25))
        #expect(animation.mips(at: 4)[0][0] == Color32(255,110,220,200))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"] != nil))
    func userSuppliedJar() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TABLETOP_CLIENT_JAR"])
        let zip = try ZipArchive(path: path)
        let waterBytes = try #require(try zip.read("assets/minecraft/textures/block/water_still.png"))
        let image = try #require(PngDecoder.decode(waterBytes))
        let metaBytes = try #require(try zip.read("assets/minecraft/textures/block/water_still.png.mcmeta"))
        let meta = try #require(TextureAnimation.parse(String(decoding: metaBytes,as: UTF8.self),image.width,image.height))
        #expect(meta.imageFrames == 32 && meta.cycleTicks == 64 && meta.frames.allSatisfy { $0.time == 2 })
        let pack = try ResourcePackAtlas(path: path)
        pack.prewarm(["minecraft:stone","minecraft:grass_block[snowy=false]","minecraft:oak_leaves[persistent=false,distance=1,waterlogged=false]"])
        let baked = pack.baked()
        #expect(baked.tileSize == 16 && baked.layers.count > 10)
        #expect(baked.face("minecraft:water[tabletop=flow]",4).random == 64)
        #expect(baked.colormaps.grass?.count == 65536)
        #expect(baked.animations.allSatisfy { $0.frameMips.count == $0.meta.imageFrames })
        #expect(baked.solidLayers.allSatisfy { layer in
            baked.layers[layer].allSatisfy { $0.a == 255 } && baked.animations.filter { $0.layer == layer }.allSatisfy { $0.frames.allSatisfy { $0.allSatisfy { $0.a == 255 } } }
        })
    }
}

private func atlasCube(_ texture: String) -> String {
    let faces = ["west","east","down","up","north","south"].map { "\"\($0)\":{\"texture\":\"#all\",\"cullface\":\"\($0)\"}" }.joined(separator: ",")
    return "{\"textures\":{\"all\":\"\(texture)\"},\"elements\":[{\"from\":[0,0,0],\"to\":[16,16,16],\"faces\":{\(faces)}}]}"
}
func atlasFluidEntries() throws -> [(String,[UInt8],Bool)] {
    var entries: [(String,[UInt8],Bool)] = []
    for name in ["water","lava"] {
        entries.append(("assets/minecraft/blockstates/\(name).json",Array("{\"variants\":{\"\":{\"model\":\"test:\(name)\"}}}".utf8),false))
        entries.append(("assets/test/models/\(name).json",Array("{\"textures\":{\"particle\":\"test:\(name)_still\"}}".utf8),false))
        entries.append(("assets/test/textures/\(name)_still.png",try atlasSolidPNG(2,Color32(50,100,150)),true))
    }
    let flowRows: [[UInt8]] = (0..<8).map { y in (0..<4).flatMap { x in
        let frame = y/4, quarter = ((y%4)/2)*2+x/2
        let alpha: UInt8 = frame == 1 && x == 2 && y == 4 ? 0 : 255
        return [UInt8(11+quarter*10+frame*50),UInt8(1),UInt8(1),alpha]
    } }
    entries.append(("assets/minecraft/textures/block/water_flow.png",try atlasPNG(4,8,8,6,flowRows),true))
    entries.append(("assets/minecraft/textures/block/water_flow.png.mcmeta",Array(#"{"animation":{"frames":[0,1]}}"#.utf8),false))
    entries.append(("assets/minecraft/textures/block/lava_flow.png",try atlasSolidPNG(4,Color32(240,80,10)),true))
    entries.append(("assets/minecraft/textures/block/water_overlay.png",try atlasSolidPNG(2,Color32(10,20,30,128)),true))
    return entries
}
private func atlasSolidPNG(_ size: Int, _ color: Color32) throws -> [UInt8] {
    try atlasPNG(size,size,8,6,Array(repeating: Array(repeating: [color.r,color.g,color.b,color.a],count: size).flatMap { $0 },count: size))
}
private func atlasPNG(_ w: Int, _ h: Int, _ depth: Int, _ type: Int, _ rows: [[UInt8]],
                      filters: [UInt8] = [], palette: [UInt8] = [], trns: [UInt8] = []) throws -> [UInt8] {
    var raw: [UInt8] = [], previous = [UInt8](repeating: 0,count: rows[0].count)
    let channels = type == 2 ? 3 : type == 4 ? 2 : type == 6 ? 4 : 1, bpp = max(1,channels*depth/8)
    for (y,row) in rows.enumerated() {
        let f = filters.isEmpty ? 0 : filters[y]; raw.append(f)
        for i in row.indices {
            let a = i >= bpp ? Int(row[i-bpp]) : 0, b = Int(previous[i]), c = i >= bpp ? Int(previous[i-bpp]) : 0
            let prediction: Int
            switch f {
            case 1: prediction = a
            case 2: prediction = b
            case 3: prediction = (a+b)/2
            case 4:
                let p = a+b-c, pa = abs(p-a), pb = abs(p-b), pc = abs(p-c)
                prediction = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
            default: prediction = 0
            }
            raw.append(UInt8(truncatingIfNeeded: Int(row[i])-prediction))
        }
        previous = row
    }
    let header = atlasBE(w)+atlasBE(h)+[UInt8(depth),UInt8(type),0,0,0]
    return [137,80,78,71,13,10,26,10]+atlasChunk("IHDR",header)
        + (palette.isEmpty ? [] : atlasChunk("PLTE",palette)) + (trns.isEmpty ? [] : atlasChunk("tRNS",trns))
        + atlasChunk("IDAT",try atlasCompress(raw,raw: false))+atlasChunk("IEND",[])
}
private func atlasBE(_ x: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: x >> 24),UInt8(truncatingIfNeeded: x >> 16),UInt8(truncatingIfNeeded: x >> 8),UInt8(truncatingIfNeeded: x)] }
private func atlasLE(_ x: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: x >> ($0*8)) } }
private func atlasChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    let body = Array(type.utf8)+payload, crc = body.withUnsafeBufferPointer { crc32(0,$0.baseAddress,uInt($0.count)) }
    return atlasBE(payload.count)+body+atlasBE(Int(crc))
}
private func atlasCompress(_ input: [UInt8], raw: Bool) throws -> [UInt8] {
    var stream = z_stream()
    guard deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,raw ? -MAX_WBITS : MAX_WBITS,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZipArchiveError("test zlib init") }
    defer { deflateEnd(&stream) }
    var output = [UInt8](repeating: 0,count: Int(compressBound(uLong(input.count)))+32)
    let status = input.withUnsafeBufferPointer { src in output.withUnsafeMutableBufferPointer { dst in
        stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress); stream.avail_in = uInt(src.count)
        stream.next_out = dst.baseAddress; stream.avail_out = uInt(dst.count)
        return deflate(&stream,Z_FINISH)
    } }
    guard status == Z_STREAM_END else { throw ZipArchiveError("test zlib deflate") }
    return Array(output.prefix(Int(stream.total_out)))
}
func atlasZip(_ entries: [(String,[UInt8],Bool)], descriptor: Bool = false) throws -> URL {
    var data: [UInt8] = [], directory: [UInt8] = []
    for (name,payload,compressed) in entries {
        let offset = data.count, bytes = compressed ? try atlasCompress(payload,raw: true) : payload
        let crc = payload.withUnsafeBufferPointer { crc32(0,$0.baseAddress,uInt($0.count)) }
        let flags = descriptor ? 8 : 0, method = compressed ? 8 : 0, nameBytes = Array(name.utf8)
        data += atlasLE(0x04034b50,4)+atlasLE(20,2)+atlasLE(flags,2)+atlasLE(method,2)+atlasLE(0,4)
        data += atlasLE(descriptor ? 0 : Int(crc),4)+atlasLE(descriptor ? 0 : bytes.count,4)+atlasLE(descriptor ? 0 : payload.count,4)
        data += atlasLE(nameBytes.count,2)+atlasLE(0,2)+nameBytes+bytes
        if descriptor { data += atlasLE(0x08074b50,4)+atlasLE(Int(crc),4)+atlasLE(bytes.count,4)+atlasLE(payload.count,4) }
        directory += atlasLE(0x02014b50,4)+atlasLE(20,2)+atlasLE(20,2)+atlasLE(flags,2)+atlasLE(method,2)+atlasLE(0,4)
        directory += atlasLE(Int(crc),4)+atlasLE(bytes.count,4)+atlasLE(payload.count,4)+atlasLE(nameBytes.count,2)
        directory += atlasLE(0,2)+atlasLE(0,2)+atlasLE(0,2)+atlasLE(0,2)+atlasLE(0,4)+atlasLE(offset,4)+nameBytes
    }
    let offset = data.count; data += directory
    let comment = Array("synthetic ZIP end comment".utf8)
    data += atlasLE(0x06054b50,4)+atlasLE(0,4)+atlasLE(entries.count,2)+atlasLE(entries.count,2)+atlasLE(directory.count,4)+atlasLE(offset,4)+atlasLE(comment.count,2)+comment
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabletop-atlas-"+UUID().uuidString+".zip")
    try Data(data).write(to: url)
    return url
}
