#if canImport(Metal)
import Metal
import simd

/// Byte layout matches Cube.metal: three matrices, followed by no extra fields.
public struct CubeUniforms {
    public var leftClipFromOrigin: simd_float4x4
    public var rightClipFromOrigin: simd_float4x4
    public var originFromTable: simd_float4x4

    public init(leftClipFromOrigin: simd_float4x4, rightClipFromOrigin: simd_float4x4,
                originFromTable: simd_float4x4) {
        self.leftClipFromOrigin = leftClipFromOrigin
        self.rightClipFromOrigin = rightClipFromOrigin
        self.originFromTable = originFromTable
    }

    public init(clipFromOrigin: [simd_float4x4], originFromTable: simd_float4x4) {
        precondition(!clipFromOrigin.isEmpty && clipFromOrigin.count <= 2)
        leftClipFromOrigin = clipFromOrigin[0]
        rightClipFromOrigin = clipFromOrigin.last!
        self.originFromTable = originFromTable
    }
}

/// Owned exclusively by the spatial render actor, never accessed from SwiftUI.
public final class CubeRenderer {
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let vertices: MTLBuffer
    private let vertexCount: Int

    public init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat,
                viewCount: Int) throws {
        let library = try device.makeDefaultLibrary(bundle: .module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Tabletop lit cube"
        descriptor.vertexFunction = library.makeFunction(name: "cubeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cubeFragment")
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.maxVertexAmplificationCount = viewCount
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw RenderError.resourceAllocation
        }
        self.depth = depth

        // Original 10 cm cube, bottom at table y=0. Face-local vertices keep hard normals.
        struct Vertex { var position: SIMD4<Float>; var normal: SIMD4<Float> }
        var mesh: [Vertex] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]),
            ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, -1]),
            ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]),
            ([0, 0, -1], [-1, 0, 0], [0, 1, 0])
        ]
        for (normal, u, v) in faces {
            for corner: SIMD2<Float> in [[-1, -1], [1, -1], [1, 1], [-1, -1], [1, 1], [-1, 1]] {
                let p = SIMD3<Float>(0, 0.05, 0) + (normal + u * corner.x + v * corner.y) * 0.05
                mesh.append(Vertex(position: SIMD4(p, 1), normal: SIMD4(normal, 0)))
            }
        }
        vertexCount = mesh.count
        guard let buffer = device.makeBuffer(bytes: mesh, length: MemoryLayout<Vertex>.stride * mesh.count) else {
            throw RenderError.resourceAllocation
        }
        vertices = buffer
    }

    public func draw(encoder: MTLRenderCommandEncoder, uniforms: CubeUniforms) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        var uniforms = uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CubeUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}

public enum RenderError: Error { case resourceAllocation }
#endif
