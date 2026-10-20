import Foundation
import simd

/// Right-handed metres, +Y up, −Z forward. No Unity Z reflection.
public struct TableFrame: Sendable {
    public var originFromTable: simd_float4x4

    public init(originFromTable: simd_float4x4) {
        self.originFromTable = originFromTable
    }

    public var tableFromOrigin: simd_float4x4 { originFromTable.inverse }

    /// The fallback placement when no table is detected: `forward` metres ahead of the head along its
    /// level look direction and `drop` metres below the eyes, turned about +Y only.
    public static func inFront(of originFromDevice: simd_float4x4, forward: Float = 0.75,
                               drop: Float = 0.35) -> TableFrame {
        let head = SIMD3<Float>(originFromDevice.columns.3.x, originFromDevice.columns.3.y, originFromDevice.columns.3.z)
        let look = -SIMD3<Float>(originFromDevice.columns.2.x, 0, originFromDevice.columns.2.z)
        let level = simd_length(look) > 1e-4 ? simd_normalize(look) : SIMD3<Float>(0, 0, -1)
        var originFromTable = simd_float4x4(simd_quatf(angle: atan2(-level.x, -level.z), axis: [0, 1, 0]))
        let position = head + level * forward - SIMD3<Float>(0, drop, 0)
        originFromTable.columns.3 = SIMD4<Float>(position, 1)
        return TableFrame(originFromTable: originFromTable)
    }

    public func tableFromDevice(originFromDevice: simd_float4x4) -> simd_float4x4 {
        tableFromOrigin * originFromDevice
    }
}

/// The look-vector formula in docs/PROTOCOL.md §3, including identity yaw ±180°.
public struct ProtocolLook: Sendable {
    public let yawDegrees: Float
    public let pitchDegrees: Float

    public init(tableFromDeviceRotation rotation: simd_quatf) {
        let forward = rotation.normalized.act(SIMD3<Float>(0, 0, -1))
        yawDegrees = atan2(-forward.x, forward.z) * 180 / .pi
        pitchDegrees = -asin(min(1, max(-1, forward.y))) * 180 / .pi
    }
}
