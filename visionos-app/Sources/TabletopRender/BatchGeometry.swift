import Foundation
import TabletopCore
import simd

/// Byte ranges in the shared uint32 index buffer. Opaque includes solid + cutout.
struct BatchRanges: Sendable, Equatable {
    let solid, cutout, transparent, waterBack: Range<Int>
    init(_ data: BatchData) throws {
        guard data.solid >= 0, data.opaque >= data.solid, data.transparent >= 0, data.waterBack >= 0,
              data.opaque <= data.indices.count,
              data.transparent <= data.indices.count - data.opaque,
              data.waterBack == data.indices.count - data.opaque - data.transparent,
              [data.solid, data.opaque, data.transparent, data.waterBack].allSatisfy({ $0.isMultiple(of: 3) }) else {
            throw BatchPreparationError.invalidGeometry
        }
        solid = 0..<data.solid
        cutout = data.solid..<data.opaque
        transparent = data.opaque..<(data.opaque + data.transparent)
        waterBack = transparent.upperBound..<data.indices.count
    }
}

/// Explicit serialization avoids Swift SIMD3's 16-byte ABI padding.
enum BatchEncoding {
    static let classicStride = 32
    static func classicBytes(_ vertices: [BatchVertex]) -> Data {
        var bytes = Data(); bytes.reserveCapacity(vertices.count * classicStride)
        func float(_ value: Float) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        for v in vertices {
            float(v.pos.x); float(v.pos.y); float(v.pos.z)
            bytes.append(contentsOf: [UInt8(bitPattern: v.nx), UInt8(bitPattern: v.ny), UInt8(bitPattern: v.nz), UInt8(bitPattern: v.nw)])
            bytes.append(contentsOf: [v.color.r, v.color.g, v.color.b, v.color.a])
            float(v.uv.x); float(v.uv.y); float(v.uv.z)
        }
        return bytes
    }
}

/// In-place heapsort uses the storage supplied by the preparation worker. Swift's
/// stable Array.sort may allocate temporary storage; this never does. Ties use keys.
enum BatchOrder {
    static func farther(_ a: SIMD3<Float>, _ ak: SIMD3<Int>, _ b: SIMD3<Float>, _ bk: SIMD3<Int>, eye: SIMD3<Float>) -> Bool {
        let da = simd_length_squared(a - eye), db = simd_length_squared(b - eye)
        if da != db { return da > db }
        if ak.x != bk.x { return ak.x < bk.x }
        if ak.y != bk.y { return ak.y < bk.y }
        return ak.z < bk.z
    }
    static func sort<T>(_ values: inout [T], before: (T, T) -> Bool) {
        guard values.count > 1 else { return }
        func sift(_ start: Int, _ end: Int) {
            var root = start
            while root * 2 + 1 < end {
                var child = root * 2 + 1
                if child + 1 < end && before(values[child], values[child + 1]) { child += 1 }
                if !before(values[root], values[child]) { return }
                values.swapAt(root, child); root = child
            }
        }
        for i in stride(from: values.count / 2 - 1, through: 0, by: -1) { sift(i, values.count) }
        for end in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(0, end); sift(0, end)
        }
    }
}
