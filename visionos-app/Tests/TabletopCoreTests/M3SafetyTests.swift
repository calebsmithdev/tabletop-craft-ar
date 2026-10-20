import Foundation
import Testing
import zlib
@testable import TabletopCore

/// All pack/image/snapshot data in these tests is generated here, without game assets.
@Suite struct M3SafetyTests {
    private func pack(_ width: Int, _ height: Int, meta: String? = nil) throws -> URL {
        var entries: [(String,[UInt8],Bool)] = [
            ("assets/test/blockstates/cube.json",Array(#"{"variants":{"":{"model":"test:cube"}}}"#.utf8),false),
            ("assets/test/models/cube.json",Array(##"{"textures":{"all":"test:tile"},"elements":[{"from":[0,0,0],"to":[16,16,16],"faces":{"west":{"texture":"#all"}}}]}"##.utf8),false),
            ("assets/test/textures/tile.png",try png(width,height),true)]
        if let meta { entries.append(("assets/test/textures/tile.png.mcmeta",Array(meta.utf8),false)) }
        return try atlasZip(entries)
    }

    @Test func oversizedTilesAndAnimationExpansionFailCheckedPublication() throws {
        for (width,height,meta,expected) in [
            (257,257,nil,ResourcePackValidationError.tileSize(257)),
            (32,33,#"{"animation":{"width":1,"height":1}}"#,.animationFrames(1056)),
            (256,1024,#"{"animation":{"width":32,"height":32}}"#,.pixelBudget)
        ] {
            let url = try pack(width,height,meta: meta)
            defer { try? FileManager.default.removeItem(at: url) }
            let atlas = try ResourcePackAtlas(path: url.path)
            atlas.prewarm(["test:cube"])
            #expect(atlas.validationError == expected)
            #expect(atlas.validationError?.localizedDescription.contains("Resource pack") == true)
            #expect(throws: expected) { try atlas.checkedBaked() }
            #expect(throws: expected) { try atlas.checkedPrewarm([]) }
            #expect(atlas.baked().layers.isEmpty)
            #expect(atlas.baked().animations.isEmpty)
        }
    }

    @Test func animationLimitsIncludeSparseSchedulesAndExactBoundary() throws {
        let onePixelFrames = #"{"animation":{"width":1,"height":1,"frames":[0,1]}}"#
        let boundary = try #require(try TextureAnimation.parseChecked(onePixelFrames,32,32))
        #expect(boundary.imageFrames == 1024 && boundary.frames.count == 2)
        #expect(throws: ResourcePackValidationError.animationFrames(1056)) {
            try TextureAnimation.parseChecked(onePixelFrames,32,33)
        }
        #expect(TextureAnimation.parse(onePixelFrames,32,33) == nil)
        let schedule = "{\"animation\":{\"frames\":[" + Array(repeating: "0,1",count: 513).joined(separator: ",") + "]}}"
        #expect(throws: ResourcePackValidationError.animationSchedule(1026)) {
            try TextureAnimation.parseChecked(schedule,1,2)
        }
        let url = try pack(1,2,meta: schedule)
        defer { try? FileManager.default.removeItem(at: url) }
        let atlas = try ResourcePackAtlas(path: url.path)
        #expect(throws: ResourcePackValidationError.animationSchedule(1026)) { try atlas.checkedPrewarm(["test:cube"]) }
    }

    @Test func oversizedSourceIsRejectedBeforePngDecode() throws {
        // A declared 8192² source would have been legal for PngDecoder. Keeping its
        // payload tiny also proves budget rejection precedes decode/fallback.
        var large = try png(2,2)
        large.replaceSubrange(16..<24,with: [0,0,32,0,0,0,32,0])
        var entries = try atlasFluidEntries()
        entries.append(("assets/test/textures/large.png",large,false))
        let url = try atlasZip(entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let atlas = try ResourcePackAtlas(path: url.path)
        try atlas.checkedPrewarm([])
        let before = try atlas.checkedBaked()
        #expect(atlas.texture("test:large",false,"test:cube").layer == -1)
        #expect(atlas.validationError == .pixelBudget)
        #expect(throws: ResourcePackValidationError.pixelBudget) { try atlas.checkedBaked() }
        #expect(before.layers.count == atlas.baked().layers.count)
    }

    @Test func storageAccountingIncludesCapacityCopiesStagingAndSourceDecode() throws {
        let raw = 16*16*4, chain = TextureMips.bytes(16,true)
        let scratch = raw*8 + 3*65536*MemoryLayout<Int>.stride
        // CPU layer + CPU frames + GPU capacity + GPU frames + two staging textures.
        #expect(try ResourcePackLimits.pixelStorageBytes(tileSize: 16,layers: 1,animationFrames: 2,
                                                        animatedLayers: 1) == (1+2+16+2+1)*(raw+chain)+scratch)
        #expect(try ResourcePackLimits.pixelStorageBytes(tileSize: 16,layers: 1,animationFrames: 2,
            animatedLayers: 1,atlasCapacity: 32,sourcePixels: 100) == (1+2+32+2+1)*(raw+chain)+scratch+3200)
        #expect(try ResourcePackLimits.atlasCapacity(for: 17) == 32)
        #expect(try ResourcePackLimits.atlasCapacity(for: 2048) == 2048)
        #expect(throws: ResourcePackValidationError.layerLimit) { try ResourcePackLimits.atlasCapacity(for: 2049) }
        #expect(throws: ResourcePackValidationError.pixelBudget) {
            try ResourcePackLimits.pixelStorageBytes(tileSize: 16,layers: 1,animationFrames: 0,
                                                     animatedLayers: 0,sourcePixels: 8192*8192)
        }
        for count in [1024,Int.max] {
            #expect(throws: ResourcePackValidationError.pixelBudget) {
                try ResourcePackLimits.pixelStorageBytes(tileSize: 256,layers: 1,animationFrames: count,animatedLayers: 1)
            }
        }
        // Spare capacity, not just logical layers, pushes this pack over the ceiling.
        #expect(try ResourcePackLimits.pixelStorageBytes(tileSize: 256,layers: 180,animationFrames: 0,
                                                        animatedLayers: 0,atlasCapacity: 180) < ResourcePackLimits.maxPixelBytes)
        #expect(throws: ResourcePackValidationError.pixelBudget) {
            try ResourcePackLimits.pixelStorageBytes(tileSize: 256,layers: 180,animationFrames: 0,animatedLayers: 0)
        }
    }

    @Test func checkedBakesPreserveSyntheticMipsFramesAndPreviousValues() throws {
        let url = try atlasZip(atlasFluidEntries())
        defer { try? FileManager.default.removeItem(at: url) }
        let atlas = try ResourcePackAtlas(path: url.path)
        try atlas.checkedPrewarm([])
        let first = try atlas.checkedBaked(), again = try atlas.checkedBaked()
        #expect(atlas.validationError == nil)
        #expect(first.layerNames == again.layerNames && first.layers == again.layers && first.mips == again.mips)
        #expect(first.layerNames.prefix(2) == ["test:water_still","test:lava_still"])
        #expect(first.layers[2][0] == Color32(11,1,1))
        #expect(first.animations.count == 4)
        for i in first.layers.indices { #expect(first.mips[i] == TextureMips.chain(first.layers[i],first.tileSize)) }
        for animation in first.animations {
            for i in animation.frames.indices {
                #expect(animation.frameMips[i] == TextureMips.chain(animation.frames[i],first.tileSize))
            }
        }
        _ = atlas.texture("minecraft:block/water_flow",false,"test:later")
        #expect(first.layers.count + 1 == (try atlas.checkedBaked()).layers.count)
        #expect(first.layers == again.layers && first.mips == again.mips)
    }

    @Test func cancelledPrewarmLayerCropAndBakeFailWithoutPublication() async throws {
        let url = try pack(2,4,meta: #"{"animation":{}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            let prewarm = try ResourcePackAtlas(path: url.path)
            let direct = try ResourcePackAtlas(path: url.path)
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: ResourcePackValidationError.cancelled) { try prewarm.checkedPrewarm(["test:cube"]) }
            #expect(throws: ResourcePackValidationError.cancelled) { try prewarm.checkedBaked() }
            #expect(direct.texture("test:tile",false,"test:cube").layer == -1)
            #expect(direct.validationError == nil)
            #expect(throws: ResourcePackValidationError.cancelled) {
                try ResourcePackAtlas.checkedCrop([Color32(1,2,3)],1,1,0,0,1,1,1)
            }
            #expect(prewarm.baked().layers.isEmpty && direct.baked().layers.isEmpty)
        }
        try await task.value
    }

    @Test func cancelledPrewarmCanResumeOnTheSameAtlas() async throws {
        let url = try atlasZip(atlasFluidEntries())
        defer { try? FileManager.default.removeItem(at: url) }
        actor Owner {
            let atlas: ResourcePackAtlas
            init(_ path: String) throws { atlas = try ResourcePackAtlas(path: path) }
            func cancelled() {
                withUnsafeCurrentTask { $0?.cancel() }
                #expect(throws: ResourcePackValidationError.cancelled) { try atlas.checkedPrewarm(["minecraft:water"]) }
                #expect(atlas.validationError == nil)
            }
            func resumed() throws -> BakedResourcePack {
                try atlas.checkedPrewarm(["minecraft:water"])
                return try atlas.checkedBaked()
            }
        }
        let owner = try Owner(url.path)
        await Task { await owner.cancelled() }.value
        let resumed = try await owner.resumed()
        #expect(!resumed.layers.isEmpty && resumed.face("minecraft:water",0).layer >= 0)
        #expect(resumed.animations.count == 4)
    }

    private func snapshot(_ origin: JSONValue = [0,0,0]) -> JSONObject {
        ["type": "chunk_snapshot", "snapshot_id": 1, "world": "test", "origin": origin,
         "dims": [1,1,1], "order": "yzx", "encoding": "rle_palette_v1", "palette": ["test:air"], "data": [0,1]]
    }
    private func biome(_ origin: JSONValue) -> JSONObject {
        ["res": 4, "encoding": "rle_palette_v1", "q_origin": origin,
         "q_dims": [1,1,1], "palette": ["test:biome"], "data": [0,1]]
    }
    private func sectioned(_ origin: JSONValue) -> JSONObject {
        var m = snapshot(origin)
        m["encoding"] = "sections_v1"; m["part"] = 0; m["parts"] = 1
        m["sections"] = [["s": [0,0,0], "data": [0,1]]]
        return m
    }

    @Test func snapshotAndBiomeCoordinatesRejectOverflowThroughParseFailure() throws {
        let bound = SnapshotLimits.maxCoordinate
        for coordinate in [Double(Int.min),Double(Int.max),-Double(bound)-1,Double(bound)+1,1.5] {
            for axis in 0..<3 {
                var coords: [JSONValue] = [0,0,0]; coords[axis] = .number(coordinate)
                let origin = JSONValue.array(coords)
                #expect(throws: (any Error).self) { try ChunkSnapshot.from(snapshot(origin)) }
                #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([sectioned(origin)]) }
                #expect(throws: (any Error).self) { try BiomeGrid.from(biome(origin)) }
                var assembler = SnapshotAssembler()
                var bad = sectioned(origin); bad["parts"] = 2
                try assembler.offer(bad,WorldModel())
                #expect(assembler.partsWaiting == 0 && assembler.tryTake()?.error != nil)
                var withBiome = snapshot(); withBiome["biomes"] = .object(biome(origin))
                try assembler.offer(withBiome,WorldModel())
                #expect(assembler.tryTake()?.error != nil)
                try assembler.offer(snapshot(),WorldModel())
                #expect(assembler.tryTake()?.snapshot?.grid == [0])
            }
        }
        for coordinate in [-bound,bound] {
            let origin = Protocol.vector(Int3(repeating: coordinate))
            #expect(try ChunkSnapshot.from(snapshot(origin)).origin.x == coordinate)
            #expect(try SectionedSnapshot.assemble([sectioned(origin)]).origin.y == coordinate)
            let grid = try #require(try BiomeGrid.from(biome(origin)))
            #expect(grid.at(0,0,0) == 0)
            let tints = BiomeTints(grid,origin: .zero,dims: [1,1,1])
            _ = tints.tint(.grass,0,0,0)
        }
    }

    @Test func otherWireWorldCoordinatesAndMarginsAreBounded() throws {
        let n = Double(SnapshotLimits.maxCoordinate)+1
        let origin: JSONValue = [.number(n),0,0]
        #expect(throws: (any Error).self) { try RegionChanged.from(["world":"test","origin":origin,"dims":[1,1,1]]) }
        #expect(throws: (any Error).self) {
            try Welcome.from(["protocol":1,"world":"test","region":["origin":origin,"dims":[1,1,1]]])
        }
        #expect(throws: (any Error).self) { try ProtocolError.from(["pos":origin]) }
        #expect(throws: (any Error).self) { try PlayerInfo.from(["pos":origin]) }
        #expect(throws: (any Error).self) { try RegionPlayer.from(["pos":origin]) }
        for field in ["changes","light"] {
            #expect(throws: (any Error).self) {
                try BlockUpdate.from(["snapshot_id":1,field:.array([.array([.number(n),0,0,1])])])
            }
        }
        var assembler = SnapshotAssembler()
        var m = snapshot(); m["view_margin"] = origin
        try assembler.offer(m,WorldModel())
        #expect(assembler.tryTake()?.error != nil)
    }

    private func png(_ width: Int, _ height: Int) throws -> [UInt8] {
        let row = [UInt8(0)] + Array(repeating: [UInt8(64),96,128,255],count: width).flatMap { $0 }
        let raw = Array(repeating: row,count: height).flatMap { $0 }
        var compressed = [UInt8](repeating: 0,count: Int(compressBound(uLong(raw.count))))
        var length = uLongf(compressed.count)
        let result = raw.withUnsafeBufferPointer { src in compressed.withUnsafeMutableBufferPointer { dst in
            compress2(dst.baseAddress,&length,src.baseAddress,uLong(raw.count),Z_BEST_SPEED)
        } }
        guard result == Z_OK else { throw ZipArchiveError("synthetic PNG compression failed") }
        func be(_ n: Int) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0*8)) } }
        func chunk(_ name: String, _ bytes: [UInt8]) -> [UInt8] {
            let payload = Array(name.utf8)+bytes
            let crc = payload.withUnsafeBufferPointer { crc32(0,$0.baseAddress,uInt($0.count)) }
            return be(bytes.count)+payload+be(Int(crc))
        }
        return [137,80,78,71,13,10,26,10]+chunk("IHDR",be(width)+be(height)+[8,6,0,0,0])
            + chunk("IDAT",Array(compressed.prefix(Int(length))))+chunk("IEND",[])
    }
}
