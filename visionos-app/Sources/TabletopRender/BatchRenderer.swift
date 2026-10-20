#if canImport(Metal)
import Metal
import TabletopCore
import simd

/// Confined to the parent's render actor. The scene outlives this renderer.
public final class BatchRenderer {
    private let pipeline: any MTLRenderPipelineState
    private let depth: any MTLDepthStencilState
    private let scene: BatchScene
    private let mailbox: BatchMailbox
    private var generation: UInt64?
    private var batches: [SIMD3<Int>: PreparedBatch] = [:]

    public init(scene: BatchScene, device: any MTLDevice, colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat, viewCount: Int) throws {
        precondition((1...2).contains(viewCount))
        self.scene = scene
        let library = try device.makeDefaultLibrary(bundle: .module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Tabletop flat batches"
        descriptor.vertexFunction = library.makeFunction(name: "batchVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "batchFragment")
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.maxVertexAmplificationCount = viewCount
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw BatchPreparationError.resourceAllocation
        }
        self.depth = depth
        mailbox = try scene.attach(device: device)
    }

    /// Elapsed milliseconds. Call once per frame, before encoding either eye.
    /// The budget covers reference swaps only, never packing or Metal allocations.
    @discardableResult
    public func consumeUploads(budgetMilliseconds: Double = 3) -> Double {
        let start = ContinuousClock.now
        let budget = min(3, max(0, budgetMilliseconds))
        func elapsed() -> Double {
            let parts = start.duration(to: .now).components
            return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        }
        var retired: [PreparedBatch] = []
        while elapsed() < budget, let update = mailbox.next(generation: generation) {
            switch update {
            case .replace(let value, let replacement):
                // Retain the old dictionary so buffer destruction occurs on the worker.
                if !batches.isEmpty { scene.retire(batches) }
                batches = replacement
                generation = value
            case .batch(let batch):
                if let previous = batches.removeValue(forKey: batch.key) { retired.append(previous) }
                if batch.indexCount > 0 { batches[batch.key] = batch }
            }
        }
        if !retired.isEmpty { scene.retire(retired) }
        return elapsed()
    }

    /// Bounds in table metres, retained from BatchData for caller-side culling/debugging.
    public func bounds(for key: SIMD3<Int>) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let batch = batches[key] else { return nil }
        return (batch.boundsMin, batch.boundsMax)
    }

    /// The caller supplies amplification mappings for layered stereo, or invokes
    /// once per eye with a one-view CubeUniforms for the single-view fallback.
    public func draw(encoder: any MTLRenderCommandEncoder, uniforms: CubeUniforms) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        var uniforms = uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CubeUniforms>.stride, index: 1)
        let left = uniforms.leftClipFromOrigin * uniforms.originFromTable
        let right = uniforms.rightClipFromOrigin * uniforms.originFromTable
        for batch in batches.values {
            guard BatchVisibility.intersects(min: batch.boundsMin, max: batch.boundsMax, left: left, right: right) else { continue }
            guard let vertices = batch.vertices, let indices = batch.indices else { continue }
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.indexCount,
                                          indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        }
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
