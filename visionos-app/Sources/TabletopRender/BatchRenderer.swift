#if canImport(Metal)
import Foundation
import Metal
import TabletopCore
import simd

struct BatchMaterialUniforms {
    var eye: SIMD4<Float>
    var fogColor: SIMD4<Float>
    var fog: SIMD4<Float>
    var options: SIMD4<Float> // atlas size, has texture, mipmaps, reserved
}
struct BatchObjectUniforms {
    var transform: SIMD4<Float>
    var cellOrigin: SIMD4<Int32>
}

struct BatchPipelines {
    let states: [any MTLRenderPipelineState]
    let overlay: any MTLRenderPipelineState
    let blend: any MTLComputePipelineState

    static func index(packed: Bool, fog: Bool, pass: Int) -> Int { (packed ? 6 : 0) + (fog ? 3 : 0) + pass }
    init(device: any MTLDevice, color: MTLPixelFormat, depth: MTLPixelFormat, views: Int) throws {
        let library: any MTLLibrary
        if let bundled = try? device.makeDefaultLibrary(bundle: .module) { library = bundled }
        else {
            // SwiftPM host tests copy .metal resources rather than building a metallib.
            guard let url = Bundle.module.url(forResource: "Batch",withExtension: "metal",subdirectory: "Shaders")
                    ?? Bundle.module.url(forResource: "Batch",withExtension: "metal") else {
                throw BatchPreparationError.resourceAllocation
            }
            library = try device.makeLibrary(source: String(contentsOf: url,encoding: .utf8),options: nil)
        }
        func descriptor() -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.colorAttachments[0].pixelFormat = color; d.depthAttachmentPixelFormat = depth
            d.maxVertexAmplificationCount = views
            return d
        }
        var states: [any MTLRenderPipelineState] = []
        for packed in [false,true] { for fog in [false,true] { for pass in 0..<3 {
            let values = MTLFunctionConstantValues()
            for (index, value) in [packed,pass == 0,fog,false,false,pass == 2].enumerated() {
                var value = value
                values.setConstantValue(&value,type: .bool,index: index)
            }
            let d = descriptor()
            d.label = "Tabletop packed=\(packed) fog=\(fog) pass=\(pass)"
            d.vertexFunction = try library.makeFunction(name: "batchVertex",constantValues: values)
            d.fragmentFunction = try library.makeFunction(name: "batchFragment",constantValues: values)
            if pass == 2 {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            states.append(try device.makeRenderPipelineState(descriptor: d))
        } } }
        self.states = states
        let d = descriptor()
        d.label = "Tabletop eye overlay"
        d.vertexFunction = library.makeFunction(name: "eyeOverlayVertex")
        d.fragmentFunction = library.makeFunction(name: "eyeOverlayFragment")
        let c = d.colorAttachments[0]!
        c.isBlendingEnabled = true; c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        overlay = try device.makeRenderPipelineState(descriptor: d)
        guard let function = library.makeFunction(name: "blendAnimation") else { throw BatchPreparationError.resourceAllocation }
        blend = try device.makeComputePipelineState(function: function)
    }
}

/// Confined to the parent's render actor. CPU geometry, textures, and sort storage
/// are allocated by BatchScene's preparation worker, never during a steady frame.
public final class BatchRenderer {
    private let pipelines: BatchPipelines
    private let solidDepth, cutoutDepth, transparentDepth, overlayDepth: any MTLDepthStencilState
    private let linearSampler, pointSampler: any MTLSamplerState
    private let fallback: PreparedPack
    private let scene: BatchScene
    private let mailbox: BatchMailbox
    private var drawing: PreparedDrawScene?
    private var pendingDrawing: PreparedDrawScene?
    private var mipmaps = true
    private var lastTick: Int64?
    public var visibleGeneration: UInt64? { drawing?.generation }

    public init(scene: BatchScene, device: any MTLDevice, colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat, viewCount: Int) throws {
        precondition((1...2).contains(viewCount))
        self.scene = scene
        pipelines = try BatchPipelines(device: device,color: colorFormat,depth: depthFormat,views: viewCount)
        func depth(_ compare: MTLCompareFunction, write: Bool) throws -> any MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = compare; d.isDepthWriteEnabled = write
            guard let value = device.makeDepthStencilState(descriptor: d) else { throw BatchPreparationError.resourceAllocation }
            return value
        }
        solidDepth = try depth(.greater,write: true)
        // Exact coplanar grass overlays need equality (the reverse-Z equivalent of Quest LEqual).
        cutoutDepth = try depth(.greaterEqual,write: true)
        transparentDepth = try depth(.greater,write: false)
        overlayDepth = try depth(.always,write: false)
        func sampler(_ mips: Bool) throws -> any MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.sAddressMode = .repeat; d.tAddressMode = .repeat
            d.minFilter = mips ? .linear : .nearest; d.magFilter = mips ? .linear : .nearest
            d.mipFilter = mips ? .linear : .notMipmapped
            guard let value = device.makeSamplerState(descriptor: d) else { throw BatchPreparationError.resourceAllocation }
            return value
        }
        linearSampler = try sampler(true); pointSampler = try sampler(false)
        fallback = try PreparedPack.makeFallback(device: device)
        mailbox = try scene.attach(device: device)
    }

    /// Reference swaps only. The worker supplies unique array storage for sorting.
    @discardableResult public func consumeUploads(budgetMilliseconds: Double = 3) -> Double {
        let start = ContinuousClock.now
        if budgetMilliseconds > 0, let replacement = mailbox.takeRenderScene() {
            if let pendingDrawing { scene.retire(pendingDrawing) }
            pendingDrawing = nil
            if replacement.pack?.uploads != nil { pendingDrawing = replacement }
            else { activate(replacement) }
        }
        if let enabled = scene.mipmapsIfAvailable() { mipmaps = enabled }
        return Self.milliseconds(since: start)
    }

    private func activate(_ replacement: PreparedDrawScene) {
        let samePack = drawing?.pack === replacement.pack
        if let previous = drawing { scene.retire(previous) }
        drawing = replacement
        if !samePack || !(replacement.pack?.animations.isEmpty ?? true) { lastTick = nil }
    }

    /// Encode staged append bytes on the frame's queue before any texture reads.
    /// Keep drawing the old scene until every required slice/mip is ordered.
    @discardableResult public func encodeUploads(commands: any MTLCommandBuffer, budgetMilliseconds: Double = 3) -> Double {
        let start = ContinuousClock.now
        if let pending = pendingDrawing, budgetMilliseconds > 0,
           pending.pack?.uploads?.encode(commands: commands,deadline: start + .seconds(budgetMilliseconds/1000)) == true {
            activate(pending); pendingDrawing = nil
        }
        return Self.milliseconds(since: start)
    }

    public func bounds(for key: SIMD3<Int>) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let batch = drawing?.batches.first(where: { $0.key == key }) else { return nil }
        return (batch.boundsMin,batch.boundsMax)
    }

    /// Call once after consumeUploads and before opening render encoders. Frame
    /// stores and interpolation scratch textures already exist. Encoded-space RGB
    /// interpolation uses exact integer 1/255 steps and keeps current-frame alpha.
    @discardableResult public func animate(commands: any MTLCommandBuffer, seconds: Double) -> Double {
        let start = ContinuousClock.now
        encodeUploads(commands: commands)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max / 20),
              let pack = drawing?.pack, !pack.animations.isEmpty else { return Self.milliseconds(since: start) }
        let tick = Int64(seconds * 20)
        guard lastTick != tick else { return Self.milliseconds(since: start) }
        // Interpolated frames are computed into preallocated scratch textures;
        // blits below copy each changed mip into its stable atlas layer.
        var compute: (any MTLComputeCommandEncoder)?
        for i in pack.animations.indices {
            let animation = pack.animations[i], sample = animation.meta.at(tick)
            let blend = Int(sample.blend * 255)
            let shown = drawing!.shown[i]
            if shown.frame == sample.frame && shown.blend == blend && (blend == 0 || shown.next == sample.next) { continue }
            if blend > 0 {
                if compute == nil {
                    compute = commands.makeComputeCommandEncoder()
                    compute?.setComputePipelineState(pipelines.blend)
                }
                guard let compute else { return Self.milliseconds(since: start) }
                let f = animation.firstFrame + sample.frame, n = animation.firstFrame + sample.next
                for mode in 0..<2 {
                    let raw = mode == 1
                    let stores = raw ? pack.rawFrames : pack.frames
                    let output = raw ? animation.rawStaging : animation.staging
                    compute.setTexture(stores[f / PreparedPack.slicesPerStore],index: 0)
                    compute.setTexture(stores[n / PreparedPack.slicesPerStore],index: 1)
                    compute.setTexture(output,index: 2)
                    for level in 0..<output.mipmapLevelCount {
                        var info = SIMD4<UInt32>(UInt32(f % PreparedPack.slicesPerStore),UInt32(n % PreparedPack.slicesPerStore),UInt32(blend),UInt32(level))
                        compute.setBytes(&info,length: MemoryLayout<SIMD4<UInt32>>.stride,index: 0)
                        let size = max(1,pack.size >> level)
                        compute.dispatchThreads(MTLSize(width: size,height: size,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
                    }
                }
            }
        }
        compute?.endEncoding()
        guard let blit = commands.makeBlitCommandEncoder() else { return Self.milliseconds(since: start) }
        for i in pack.animations.indices {
            let animation = pack.animations[i], sample = animation.meta.at(tick)
            let blend = Int(sample.blend * 255), shown = drawing!.shown[i]
            if shown.frame == sample.frame && shown.blend == blend && (blend == 0 || shown.next == sample.next) { continue }
            let frame = animation.firstFrame + sample.frame
            for mode in 0..<2 {
                    let raw = mode == 1
                let store = raw ? pack.copyRawFrames : pack.copyFrames
                let source = blend > 0 ? (raw ? animation.copyRawStaging : animation.copyStaging) : store[frame / PreparedPack.slicesPerStore]
                let destination = raw ? pack.nearest : pack.atlas
                for level in 0..<destination.mipmapLevelCount {
                    let size = max(1,pack.size >> level)
                    blit.copy(from: source,sourceSlice: blend > 0 ? 0 : frame % PreparedPack.slicesPerStore,sourceLevel: level,
                              sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),sourceSize: MTLSize(width: size,height: size,depth: 1),
                              to: destination,destinationSlice: animation.layer,destinationLevel: level,destinationOrigin: MTLOrigin(x: 0,y: 0,z: 0))
                }
            }
            drawing!.shown[i] = AnimationShown(frame: sample.frame,next: sample.next,blend: blend)
        }
        blit.endEncoding(); lastTick = tick
        return Self.milliseconds(since: start)
    }

    public func draw(encoder: any MTLRenderCommandEncoder, uniforms: CubeUniforms,
                     eye: SIMD3<Float> = .zero, medium: EyeMedium = .air, look: EyeLook = EyeLook()) {
        guard drawing != nil else { return }
        var uniforms = uniforms
        encoder.setVertexBytes(&uniforms,length: MemoryLayout<CubeUniforms>.stride,index: 1)
        if look.tintAlpha > 0 {
            encoder.setRenderPipelineState(pipelines.overlay); encoder.setDepthStencilState(overlayDepth)
            encoder.setCullMode(.front); encoder.setFrontFacing(.counterClockwise)
            var head = SIMD4(eye,1)
            var tint = SIMD4<Float>(look.tint.r,look.tint.g,look.tint.b,look.tintAlpha)
            encoder.setVertexBytes(&head,length: MemoryLayout<SIMD4<Float>>.stride,index: 2)
            encoder.setFragmentBytes(&tint,length: MemoryLayout<SIMD4<Float>>.stride,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 36)
        }
        let pack = drawing!.pack ?? fallback
        let fog = look.strength > 0 // Includes EyeMediumFilter fade after exiting a fluid.
        var material = BatchMaterialUniforms(eye: SIMD4(eye,0),fogColor: SIMD4(look.fog.r,look.fog.g,look.fog.b,1),
                                            fog: SIMD4(look.start,1/max(1e-6,look.end-look.start),look.strength,0),
                                            options: SIMD4(Float(pack.size),drawing!.pack == nil ? 0 : 1,mipmaps ? 1 : 0,0))
        encoder.setVertexBytes(&material,length: MemoryLayout<BatchMaterialUniforms>.stride,index: 3)
        encoder.setFragmentBytes(&material,length: MemoryLayout<BatchMaterialUniforms>.stride,index: 0)
        encoder.setFragmentTexture(mipmaps ? pack.atlas : pack.nearest,index: 0)
        encoder.setFragmentSamplerState(mipmaps ? linearSampler : pointSampler,index: 0)
        encoder.setFragmentBuffer(pack.random,offset: 0,index: 1)
        encoder.setCullMode(.back); encoder.setFrontFacing(.counterClockwise)
        let left = uniforms.leftClipFromOrigin * uniforms.originFromTable
        let right = uniforms.rightClipFromOrigin * uniforms.originFromTable
        func draw(_ batch: PreparedBatch, _ range: Range<Int>, _ pass: Int) {
            guard !range.isEmpty, let vertices = batch.vertices, let indices = batch.indices,
                  BatchVisibility.intersects(min: batch.boundsMin,max: batch.boundsMax,left: left,right: right) else { return }
            encoder.setRenderPipelineState(pipelines.states[BatchPipelines.index(packed: batch.packed,fog: fog,pass: pass)])
            var object = BatchObjectUniforms(transform: batch.transform,cellOrigin: batch.cellOrigin)
            encoder.setVertexBytes(&object,length: MemoryLayout<BatchObjectUniforms>.stride,index: 2)
            encoder.setVertexBuffer(vertices,offset: 0,index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,indexCount: range.count,indexType: .uint32,indexBuffer: indices,indexBufferOffset: range.lowerBound*4)
        }
        encoder.setDepthStencilState(solidDepth)
        for batch in drawing!.batches { draw(batch,batch.ranges.solid,0) }
        encoder.setDepthStencilState(cutoutDepth)
        for batch in drawing!.batches { draw(batch,batch.ranges.cutout,1) }
        BatchOrder.sort(&drawing!.transparent) {
            BatchOrder.farther(($0.boundsMin+$0.boundsMax)*0.5,$0.key,($1.boundsMin+$1.boundsMax)*0.5,$1.key,eye: eye)
        }
        encoder.setDepthStencilState(transparentDepth)
        for batch in drawing!.transparent {
            draw(batch,batch.ranges.transparent,2)
            if medium == .water { draw(batch,batch.ranges.waterBack,2) }
        }
    }
    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let p = start.duration(to: .now).components
        return Double(p.seconds)*1000+Double(p.attoseconds)/1e15
    }
}
/// Conservative homogeneous clipping: a box is hidden only if all eight
/// corners lie beyond the same clip plane in every eye. Reverse Z still uses
/// Metal's 0 <= z <= w volume. Crossing/near-plane boxes remain visible.
public enum BatchVisibility {
    public static func intersects(min: SIMD3<Float>, max: SIMD3<Float>, left: simd_float4x4, right: simd_float4x4) -> Bool {
        intersects(min: min, max: max, matrix: left) || intersects(min: min, max: max, matrix: right)
    }

    public static func intersects(min: SIMD3<Float>, max: SIMD3<Float>, clipFromTable: [simd_float4x4]) -> Bool {
        clipFromTable.contains { intersects(min: min, max: max, matrix: $0) }
    }

    private static func intersects(min: SIMD3<Float>, max: SIMD3<Float>, matrix: simd_float4x4) -> Bool {
        // Each bit starts as a possible separating plane. A corner inside that
        // plane clears it. Fixed-size SIMD values and scalar masks need no arrays.
        var outsideEveryCorner: UInt8 = 0b11_1111
        for corner in 0..<8 {
            let p = matrix * SIMD4<Float>(corner & 1 == 0 ? min.x : max.x,
                                          corner & 2 == 0 ? min.y : max.y,
                                          corner & 4 == 0 ? min.z : max.z, 1)
            var outside: UInt8 = 0
            if p.x < -p.w { outside |= 1 }
            if p.x > p.w { outside |= 2 }
            if p.y < -p.w { outside |= 4 }
            if p.y > p.w { outside |= 8 }
            if p.z < 0 { outside |= 16 }
            if p.z > p.w { outside |= 32 }
            outsideEveryCorner &= outside
        }
        return outsideEveryCorner == 0
    }
}
#endif
