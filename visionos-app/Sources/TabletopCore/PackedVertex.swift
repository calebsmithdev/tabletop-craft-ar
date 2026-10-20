// Port of quest-app/Assets/Scripts/World/SectionBatches.cs at 281c614.
// CPU upload encoding only; no platform rendering dependency or Unity Z mirror.
import Foundation

public struct PackedVertex: Equatable, Sendable {
    public static let size = 20
    public static let posScale: Float = 64, uvScale: Float = 1024
    public var x, y, z, meta: Int16
    public var color: Color32
    public var u, v, layer, table: Int16
    public var position: SIMD3<Float> { SIMD3(Float(x),Float(y),Float(z))/Self.posScale }
    public var uv: SIMD2<Float> { SIMD2(Float(u),Float(v))/Self.uvScale }
    public var light: Int { Int(meta)&255 }
    /// +X,-X,+Y,-Y,+Z,-Z,none in the tabletop frame.
    public var dir: Int { Int(meta)>>8 }
    public static func shade(_ nx: Int8, _ ny: Int8, _ nz: Int8) -> (Float,Int) {
        let x = max(-1,Float(nx)/127), y = max(-1,Float(ny)/127), z = max(-1,Float(nz)/127)
        if abs(y) > 0.9 { return (y > 0 ? 1 : 0.5,y > 0 ? 2 : 3) }
        if abs(z) > 0.9 { return (0.8,z > 0 ? 4 : 5) }
        if abs(x) > 0.9 { return (0.6,x > 0 ? 0 : 1) }
        return (1,6)
    }
    public static func tryPack(_ vertex: BatchVertex, _ position: SIMD3<Float>? = nil) -> PackedVertex? {
        let p = position ?? vertex.pos
        let values = [p.x*posScale,p.y*posScale,p.z*posScale,vertex.uv.x*uvScale,vertex.uv.y*uvScale].map { $0.rounded(.toNearestOrEven) }
        guard values.allSatisfy({ $0.isFinite && $0 >= -32767 && $0 <= 32767 }), vertex.uv.z.isFinite else { return nil }
        let (shade,dir) = shade(vertex.nx,vertex.ny,vertex.nz)
        let c = vertex.color
        func scaled(_ channel: UInt8) -> UInt8 { UInt8((Float(channel)*shade).rounded(.toNearestOrEven)) }
        guard vertex.uv.z < Float(Int32.max) else { return nil }
        let z = vertex.uv.z < 0 ? -1 : Int(vertex.uv.z.rounded(.toNearestOrEven))
        // Decode the same SNorm8 mapping as the classic shader (including the -128 alias).
        let normalized = max(-1,Float(vertex.nw)/127)
        let code = (Int((normalized*127).rounded(.toNearestOrEven))+128-15)&255
        let table = z < 0 ? 0 : z/4096, layer = z < 0 ? -1 : z-table*4096
        guard let t = Int16(exactly: table), let l = Int16(exactly: layer) else { return nil }
        return PackedVertex(x: Int16(values[0]),y: Int16(values[1]),z: Int16(values[2]),meta: Int16(code+256*dir),color: Color32(scaled(c.r),scaled(c.g),scaled(c.b),c.a),u: Int16(values[3]),v: Int16(values[4]),layer: l,table: t)
    }
    /// Stable 20-byte little-endian layout; independent of Swift SIMD alignment.
    public func appendBytes(to bytes: inout Data) {
        func append(_ value: Int16) {
            let bits = UInt16(bitPattern: value)
            bytes.append(UInt8(truncatingIfNeeded: bits)); bytes.append(UInt8(truncatingIfNeeded: bits>>8))
        }
        append(x); append(y); append(z); append(meta)
        bytes.append(contentsOf: [color.r,color.g,color.b,color.a])
        append(u); append(v); append(layer); append(table)
    }
}

/// The baked atlas owns these flags. Unknown layers use the cutout pass.
public enum SolidLayers {
    public static func face(_ uvz: Float, _ layers: Set<Int>, enabled: Bool = true) -> Bool {
        guard enabled, uvz.isFinite else { return false }
        if uvz < 0 { return true }
        guard uvz < Float(Int32.max) else { return false }
        let z = Int(uvz.rounded(.toNearestOrEven))
        let table = z/4096, layer = z-table*4096
        if table == 64 { return (0..<4).allSatisfy { layers.contains(layer+$0) } }
        return layers.contains(layer)
    }
}

extension BatchData {
    /// Nil selects the classic vertex format when positions/UVs exceed the packed range.
    public func packedBytes() -> Data? {
        var bytes = Data(); bytes.reserveCapacity(verts.count*PackedVertex.size)
        for vertex in verts {
            guard let packed = PackedVertex.tryPack(vertex) else { return nil }
            packed.appendBytes(to: &bytes)
        }
        return bytes
    }
}
