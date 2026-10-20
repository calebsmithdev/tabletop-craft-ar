import Foundation
import Metal
import Testing
import simd
@testable import TabletopCore
@testable import TabletopRender

@Suite struct M3bRenderTests {
    private func data() -> BatchData {
        var d = BatchData()
        var v = BatchVertex(pos: [1,2,3],color: Color32(200,150,100,255),uv: [0.25,0.75,8199])
        v.ny = 127; v.nw = 127
        d.verts = [v,v,v]; d.indices = [0,1,2,0,1,2,0,1,2,0,1,2]
        d.solid = 3; d.opaque = 6; d.transparent = 3; d.waterBack = 3
        d.min = [1,2,3]; d.max = [1,2,3]
        return d
    }
    private func pack(_ red: UInt8, animated: Bool = false, extraLayers: Int = 0, appendedAnimation: Bool = false, tileSize: Int = 4) throws -> BakedResourcePack {
        var layers = [[Color32](repeating: Color32(red,20,30,200),count: 16),
                      [Color32](repeating: Color32(40,50,60),count: 16)]
        for i in 0..<extraLayers { layers.append([Color32](repeating: Color32(UInt8(i+60),50,60),count: 16)) }
        let frames = [layers[0],[Color32](repeating: Color32(220,100,80,100),count: 16)]
        let animation = ResourcePackAtlasAnimation(layer: 0,
            meta: try #require(TextureAnimation.parse(#"{"animation":{"frametime":4,"interpolate":true}}"#,4,8)),
            frames: frames,frameMips: frames.map { TextureMips.chain($0,4) })
        var animations = animated ? [animation] : []
        if appendedAnimation {
            animations.append(ResourcePackAtlasAnimation(layer: 2,meta: animation.meta,
                frames: frames,frameMips: frames.map { TextureMips.chain($0,4) }))
        }
        return BakedResourcePack(faces: [:],models: [:],shapeOverrides: [:],tileSize: tileSize,
                                 layerNames: ["synthetic:a","synthetic:b"] + (0..<extraLayers).map { "synthetic:extra\($0)" },layers: layers,
                                 mips: layers.map { TextureMips.chain($0,4) },animations: animations,
                                 solidLayers: [1],randomUv: RandomUv(),randomTables: RandomUv().packed(),colormaps: BiomeColormaps())
    }

    @Test func exactClassicAndPackedLayoutsAndAllRanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var d = data()
        let classic = BatchEncoding.classicBytes(d.verts)
        #expect(classic.count == 3*32)
        func float(at: Int) -> Float {
            var bits: UInt32 = 0
            for i in 0..<4 { bits |= UInt32(classic[at+i]) << (i*8) }
            return Float(bitPattern: bits)
        }
        #expect(float(at: 0) == 1 && float(at: 8) == 3)
        #expect(Array(classic[12..<20]) == [0,127,0,127,200,150,100,255])
        #expect(float(at: 20) == 0.25 && float(at: 28) == 8199)
        let ranges = try BatchRanges(d)
        #expect(ranges.solid == 0..<3 && ranges.cutout == 3..<6)
        #expect(ranges.transparent == 6..<9 && ranges.waterBack == 9..<12)
        func prepare(_ d: BatchData) throws -> PreparedBatch {
            try PreparedBatch.prepare(BatchUpload(generation: 3,key: .zero,data: d,position: [10,0,0],blockSize: 0.1,center: [1,0,0],
                                                   cellOrigin: [30_000_000,-64,-30_000_000]),revision: 2,device: device)
        }
        let packed = try prepare(d)
        #expect(packed.packed && packed.vertices?.length == d.verts.count*20)
        #expect(packed.indexCount == 12 && packed.ranges == ranges)
        #expect(packed.cellOrigin == [30_000_000,-64,-30_000_000,0])
        #expect(abs(packed.boundsMin.x - 1) < 1e-6)
        d.verts[0].uv.x = 33
        let fallback = try prepare(d)
        #expect(!fallback.packed && fallback.vertices?.length == d.verts.count*32)
        d.opaque = 7
        #expect(throws: BatchPreparationError.self) { try BatchRanges(d) }
    }

    @Test func transparentSortMovesWithEyeAndBreaksTies() {
        struct Item { let key: SIMD3<Int>; let center: SIMD3<Float> }
        var values = [Item(key: [0,0,0],center: [1,0,0]),Item(key: [2,0,0],center: [5,0,0]),Item(key: [1,0,0],center: [-5,0,0])]
        func sort(_ eye: SIMD3<Float>) {
            BatchOrder.sort(&values) { BatchOrder.farther($0.center,$0.key,$1.center,$1.key,eye: eye) }
        }
        sort(.zero)
        #expect(values.map(\.key.x) == [1,2,0])
        sort([10,0,0])
        #expect(values.map(\.key.x) == [1,0,2])
        sort([-10,0,0])
        #expect(values.map(\.key.x) == [2,0,1])
    }

    @Test func everyMaterialPipelineBuildsForBothStereoModes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for views in 1...2 {
            let p = try BatchPipelines(device: device,color: .bgra8Unorm_srgb,depth: .depth32Float,views: views)
            #expect(p.states.count == 12)
            var indices = Set<Int>()
            for packed in [false,true] { for fog in [false,true] { for pass in 0..<3 {
                indices.insert(BatchPipelines.index(packed: packed,fog: fog,pass: pass))
            } } }
            #expect(indices == Set(0..<12))
        }
    }

    @Test func waterBackRangeActuallyDrawsOnlyWhileUnderwater() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let preparation = DispatchQueue(label: "test.m3b.waterback")
        let scene = BatchScene(preparationQueue: preparation)
        let renderer = try BatchRenderer(scene: scene, device: device, colorFormat: .bgra8Unorm_srgb,
                                         depthFormat: .depth32Float, viewCount: 1)
        var data = BatchData()
        data.verts = [[-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]].map {
            BatchVertex(pos: $0, color: Color32(255,0,0,128), uv: [0,0,-1])
        }
        // Both windings make this a pass-toggle check independent of camera handedness.
        data.indices = [0,1,2,0,2,3,0,2,1,0,3,2]
        data.waterBack = 12; data.min = [-0.5,-0.5,0.5]; data.max = [0.5,0.5,0.5]
        scene.beginGeneration(1)
        scene.publish(BatchUpload(generation: 1, key: .zero, data: data, position: .zero, blockSize: 1, center: .zero))
        preparation.sync {}; renderer.consumeUploads()
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 32, height: 32, mipmapped: false)
        colorDescriptor.storageMode = .shared; colorDescriptor.usage = .renderTarget
        let color = try #require(device.makeTexture(descriptor: colorDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 32, height: 32, mipmapped: false)
        depthDescriptor.storageMode = .private; depthDescriptor.usage = .renderTarget
        let depth = try #require(device.makeTexture(descriptor: depthDescriptor))
        let queue = try #require(device.makeCommandQueue())
        func render(_ medium: EyeMedium, look: EyeLook = EyeLook()) throws -> [UInt8] {
            let commands = try #require(queue.makeCommandBuffer()), pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 0
            let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: 32, height: 32, znear: 0, zfar: 1))
            renderer.draw(encoder: encoder, uniforms: CubeUniforms(clipFromOrigin: [matrix_identity_float4x4], originFromTable: matrix_identity_float4x4), medium: medium, look: look)
            encoder.endEncoding(); commands.commit(); commands.waitUntilCompleted()
            #expect(commands.status == .completed)
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                color.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(16,16,1,1), mipmapLevel: 0)
            }
            return pixel
        }
        #expect(try render(.air) == [0,0,0,0])
        let water = try render(.water)
        #expect(water[2] > 150 && water[3] >= 127)
        #expect(try render(.lava) == [0,0,0,0])
        // Isolate block fog from the passthrough overlay: a near blue fog must
        // replace the red face, while tintAlpha remains zero.
        let fog = EyeLook(fog: Rgb(0,0,1), start: 0, end: 0.25, strength: 1)
        let fogged = try render(.water, look: fog)
        #expect(fogged[0] > 150 && fogged[2] == 0 && fogged[3] >= 127)
    }

    @Test func packAndMeshGenerationPublishTogether() throws {
        let queue = DispatchQueue(label: "test.m3b.pack")
        // Use an explicitly drained queue to avoid timers or tests racing GPU preparation.
        let controlled = BatchScene(preparationQueue: queue)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let mailbox = try controlled.attach(device: device)
        func upload(_ generation: UInt64) {
            controlled.publish(BatchUpload(generation: generation,key: .zero,data: data(),position: .zero,blockSize: 0.1,center: .zero))
        }
        controlled.beginGeneration(1,pack: try pack(10)); upload(1); queue.sync {}
        let initial = try #require(mailbox.takeRenderScene())
        #expect(initial.generation == 1 && initial.batches.count == 1)
        let oldPack = try #require(initial.pack)
        controlled.beginGeneration(2,pack: try pack(200)); upload(2); queue.sync {}
        #expect(mailbox.takeRenderScene() == nil)
        let reopened = try controlled.attach(device: device)
        let old = try #require(reopened.takeRenderScene())
        #expect(old.generation == 1 && old.pack === oldPack)
        controlled.completeGeneration(2)
        let next = try #require(mailbox.takeRenderScene())
        #expect(next.generation == 2 && next.pack !== oldPack)
        #expect(next.batches.allSatisfy { $0.generation == 2 })
        controlled.beginGeneration(3); upload(3); queue.sync {}; controlled.completeGeneration(3)
        let preserved = try #require(mailbox.takeRenderScene())
        #expect(preserved.pack === next.pack)
        controlled.setMipmaps(false)
        #expect(controlled.mipmapsIfAvailable() == false)
    }

    @Test func packBudgetRejectsBeforeGPUAllocation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pixels = [Color32](repeating: Color32(255,255,255),count: 256*256)
        let mips = TextureMips.chain(pixels,256)
        // COW storage keeps the test small; accounting must charge every logical layer.
        let source = BakedResourcePack(faces: [:],models: [:],shapeOverrides: [:],tileSize: 256,
            layerNames: (0..<600).map { "budget:\($0)" },layers: Array(repeating: pixels,count: 600),
            mips: Array(repeating: mips,count: 600),animations: [],solidLayers: [],
            randomUv: RandomUv(),randomTables: [],colormaps: BiomeColormaps())
        #expect(throws: ResourcePackValidationError.pixelBudget) {
            try PreparedPack.prepare(source,device: device)
        }
    }

    @Test func packFailurePublishesFlatFallbackAndReleasesPixels() throws {
        let queue = DispatchQueue(label: "test.m3b.pack-failure")
        let scene = BatchScene(preparationQueue: queue)
        let device = try #require(MTLCreateSystemDefaultDevice())
        scene.beginGeneration(1,pack: try pack(20))
        #expect(scene.retainsPackSource && scene.packPreparationPending)
        let mailbox = try scene.attach(device: device)
        scene.publish(BatchUpload(generation: 1,key: .zero,data: data(),position: .zero,blockSize: 0.1,center: .zero))
        queue.sync {}
        #expect(mailbox.takeRenderScene()?.pack != nil)
        #expect(!scene.retainsPackSource && !scene.packPreparationPending)
        scene.beginGeneration(2,pack: try pack(20,tileSize: 257))
        scene.publish(BatchUpload(generation: 2,key: .zero,data: data(),position: .zero,blockSize: 0.1,center: .zero))
        scene.completeGeneration(2)
        queue.sync {}
        let fallback = try #require(mailbox.takeRenderScene())
        #expect(fallback.generation == 2 && fallback.pack == nil && fallback.batches.count == 1)
        #expect(scene.preparationError != nil && scene.preparationFailureCount == 1 && !scene.packPreparationPending)
        #expect(!scene.retainsPackSource && !scene.packPreparationPending)
        scene.updatePack(try pack(30),generation: 2)
        queue.sync {}
        #expect(mailbox.takeRenderScene()?.pack != nil)
        #expect(scene.preparationError == nil && !scene.retainsPackSource)

        let fresh = BatchScene(preparationQueue: queue)
        let freshMailbox = try fresh.attach(device: device)
        fresh.beginGeneration(1,pack: try pack(20,tileSize: 257))
        fresh.publish(BatchUpload(generation: 1,key: .zero,data: data(),position: .zero,blockSize: 0.1,center: .zero))
        queue.sync {}
        let firstFallback = try #require(freshMailbox.takeRenderScene())
        #expect(firstFallback.generation == 1 && firstFallback.pack == nil && firstFallback.batches.count == 1)
        #expect(fresh.preparationError != nil && !fresh.retainsPackSource)
    }

    @Test func paletteAppendReusesGenerationAndStorageBeforeMeshPublication() throws {
        let queue = DispatchQueue(label: "test.m3b.pack-append")
        let scene = BatchScene(preparationQueue: queue)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try BatchRenderer(scene: scene,device: device,colorFormat: .bgra8Unorm_srgb,depthFormat: .depth32Float,viewCount: 1)
        let mailbox = try scene.attach(device: device)
        scene.beginGeneration(1,pack: try pack(20,animated: true))
        scene.publish(BatchUpload(generation: 1,key: .zero,data: data(),position: .zero,blockSize: 0.1,center: .zero))
        queue.sync {}
        let original = try #require(mailbox.takeRenderScene()?.pack)
        #expect(original.capacity > original.layerCount)
        let added = try pack(20,animated: true,extraLayers: 1,appendedAnimation: true)
        queue.suspend()
        do {
            defer { queue.resume() }
            scene.updatePack(added,generation: 1)
            scene.publish(BatchUpload(generation: 1,key: [1,0,0],data: data(),position: .zero,blockSize: 0.1,center: .zero))
            let reopened = try scene.attach(device: device)
            let before = try #require(reopened.takeRenderScene())
            #expect(before.pack === original && before.batches.count == 1)
            #expect(mailbox.takeRenderScene() == nil)
        }
        queue.sync {}
        let updated = try #require(mailbox.takeRenderScene())
        let extended = try #require(updated.pack)
        #expect(updated.generation == 1 && updated.batches.count == 2)
        #expect(extended.atlas === original.atlas && extended.nearest === original.nearest)
        #expect(extended.frames[0] === original.frames[0])
        #expect(extended.animations.count == 2 && extended.frames.count == 2)
        #expect(!scene.retainsPackSource && !scene.packPreparationPending)
        renderer.consumeUploads()
        let commandQueue = try #require(device.makeCommandQueue())
        for tick: Int64 in [0,1,4,5] {
            let commands = try #require(commandQueue.makeCommandBuffer())
            renderer.animate(commands: commands,seconds: Double(tick)/20)
            commands.commit(); commands.waitUntilCompleted()
            #expect(commands.status == .completed)
            for animation in added.animations { for level in 0..<3 {
                let n = max(1,4 >> level)
                var bytes = [UInt8](repeating: 0,count: n*n*4)
                bytes.withUnsafeMutableBytes {
                    extended.atlas.getBytes($0.baseAddress!,bytesPerRow: n*4,bytesPerImage: n*n*4,
                        from: MTLRegionMake2D(0,0,n,n),mipmapLevel: level,slice: animation.layer)
                }
                #expect(bytes == animation.mips(at: tick)[level].flatMap { [$0.r,$0.g,$0.b,$0.a] })
            } }
        }
        let larger = try pack(20,animated: true,extraLayers: 15,appendedAnimation: true)
        queue.suspend()
        do {
            defer { queue.resume() }
            scene.updatePack(larger,generation: 1)
            let duringGrowth = try scene.attach(device: device)
            #expect(duringGrowth.takeRenderScene()?.pack === extended)
        }
        queue.sync {}
        let grown = try #require(mailbox.takeRenderScene())
        #expect(grown.generation == 1 && grown.batches.count == 2)
        #expect(grown.pack?.atlas !== extended.atlas && grown.pack?.layerCount == 17)
        #expect(scene.preparationError == nil && !scene.retainsPackSource)
    }

    @Test func everyLayerMipAndAnimationFrameUploadsAndBlits() throws {
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = DispatchQueue(label: "test.m3b.animation")
        let scene = BatchScene(preparationQueue: queue)
        let renderer = try BatchRenderer(scene: scene,device: device,colorFormat: .bgra8Unorm_srgb,depthFormat: .depth32Float,viewCount: 2)
        let mailbox = try scene.attach(device: device)
        let source = try pack(20,animated: true)
        scene.beginGeneration(1,pack: source)
        scene.publish(BatchUpload(generation: 1,key: .zero,data: data(),position: .zero,blockSize: 0.1,center: .zero))
        queue.sync {}
        let prepared = try #require(mailbox.takeRenderScene()?.pack)
        func pixels(_ texture: any MTLTexture, _ slice: Int, _ level: Int) -> [UInt8] {
            let n = max(1,texture.width >> level)
            var result = [UInt8](repeating: 0,count: n*n*4)
            result.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!,bytesPerRow: n*4,bytesPerImage: n*n*4,
                                 from: MTLRegionMake2D(0,0,n,n),mipmapLevel: level,slice: slice)
            }
            return result
        }
        #expect(prepared.atlas.pixelFormat == .rgba8Unorm_srgb)
        #expect(prepared.frames.allSatisfy { $0.pixelFormat == .rgba8Unorm })
        #expect(prepared.copyFrames.allSatisfy { $0.pixelFormat == prepared.atlas.pixelFormat })
        #expect(prepared.animations.allSatisfy { $0.copyStaging.pixelFormat == prepared.atlas.pixelFormat })
        for layer in 0..<2 { for level in 0..<3 {
            let expected = source.mips[layer][level].flatMap { [$0.r,$0.g,$0.b,$0.a] }
            #expect(pixels(prepared.atlas,layer,level) == expected)
        } }
        renderer.consumeUploads()
        #expect(renderer.visibleGeneration == 1)
        let commandQueue = try #require(device.makeCommandQueue())
        for tick: Int64 in [0,1,2,4,5] {
            let commands = try #require(commandQueue.makeCommandBuffer())
            renderer.animate(commands: commands,seconds: Double(tick)/20)
            commands.commit(); commands.waitUntilCompleted()
            #expect(commands.status == .completed)
            for level in 0..<3 {
                let expected = source.animations[0].mips(at: tick)[level].flatMap { [$0.r,$0.g,$0.b,$0.a] }
                #expect(pixels(prepared.atlas,0,level) == expected)
            }
            #expect(pixels(prepared.nearest,0,0) == pixels(prepared.atlas,0,0))
        }
    }

    @Test func emptyAtlasReusePreservesItsInitializedWhiteFallback() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = BakedResourcePack(faces: [:],models: [:],shapeOverrides: [:],tileSize: 4,
            layerNames: [],layers: [],mips: [],animations: [],solidLayers: [],
            randomUv: RandomUv(),randomTables: [],colormaps: BiomeColormaps())
        let first = try PreparedPack.prepare(source,device: device)
        let reused = try PreparedPack.prepare(source,device: device,extending: first)
        #expect(reused.atlas === first.atlas && reused.nearest === first.nearest)
        #expect(reused.uploads == nil)
        for texture in [reused.atlas,reused.nearest] { for level in 0..<texture.mipmapLevelCount {
            let n = max(1,4 >> level)
            var bytes = [UInt8](repeating: 0,count: n*n*4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!,bytesPerRow: n*4,bytesPerImage: n*n*4,
                    from: MTLRegionMake2D(0,0,n,n),mipmapLevel: level,slice: 0)
            }
            #expect(bytes.allSatisfy { $0 == 255 })
        } }
    }

    @Test func incrementalSlicesAreStagedUntilGPUCopyIncludingSkippedPublication() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let initial = try PreparedPack.prepare(pack(20),device: device)
        func pixels(_ texture: any MTLTexture, _ slice: Int, _ level: Int) -> [UInt8] {
            let n = max(1,texture.width >> level)
            var bytes = [UInt8](repeating: 0,count: n*n*4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!,bytesPerRow: n*4,bytesPerImage: n*n*4,
                    from: MTLRegionMake2D(0,0,n,n),mipmapLevel: level,slice: slice)
            }
            return bytes
        }
        // Initialize unused slices before any command buffer can see this atlas.
        for texture in [initial.atlas,initial.nearest] { for slice in 2..<4 { for level in 0..<texture.mipmapLevelCount {
            let n = max(1,4 >> level), bytes = [UInt8](repeating: 7,count: n*n*4)
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0,0,n,n),mipmapLevel: level,slice: slice,
                    withBytes: $0.baseAddress!,bytesPerRow: n*4,bytesPerImage: n*n*4)
            }
        } } }
        let intermediate = try PreparedPack.prepare(pack(20,extraLayers: 1),device: device,extending: initial)
        let source = try pack(20,extraLayers: 2)
        let final = try PreparedPack.prepare(source,device: device,extending: intermediate)
        #expect(final.atlas === initial.atlas && final.nearest === initial.nearest)
        let uploads = try #require(final.uploads)
        #expect(uploads.pendingByteCount > 0)
        for texture in [final.atlas,final.nearest] { for slice in 2..<4 { for level in 0..<texture.mipmapLevelCount {
            #expect(pixels(texture,slice,level).allSatisfy { $0 == 7 })
        } } }
        let empty = try #require(queue.makeCommandBuffer())
        #expect(!uploads.encode(commands: empty,deadline: .now))
        empty.commit(); empty.waitUntilCompleted()
        let commands = try #require(queue.makeCommandBuffer())
        #expect(uploads.encode(commands: commands,deadline: .now + .seconds(1)))
        commands.commit(); commands.waitUntilCompleted()
        #expect(commands.status == .completed && uploads.pendingByteCount == 0)
        for slice in source.layers.indices { for level in source.mips[slice].indices {
            #expect(pixels(final.atlas,slice,level) == source.mips[slice][level].flatMap { [$0.r,$0.g,$0.b,$0.a] })
        } }
        for slice in source.layers.indices {
            #expect(pixels(final.nearest,slice,0) == source.layers[slice].flatMap { [$0.r,$0.g,$0.b,$0.a] })
        }
        // A second renderer/queue waits for the upload event and never replays
        // stale CPU slices over a texture subsequently changed by animation.
        let otherQueue = try #require(device.makeCommandQueue())
        let other = try #require(otherQueue.makeCommandBuffer())
        #expect(uploads.encode(commands: other,deadline: .now + .seconds(1)))
        other.commit(); other.waitUntilCompleted()
        #expect(other.status == .completed)
    }
}
