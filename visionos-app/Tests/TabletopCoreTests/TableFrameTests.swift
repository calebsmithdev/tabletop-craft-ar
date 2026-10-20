import Testing
import simd
@testable import TabletopCore

@Test func identityFacesNorth() {
    let look = ProtocolLook(tableFromDeviceRotation: simd_quatf(angle: 0, axis: [0, 1, 0]))
    #expect(abs(abs(look.yawDegrees) - 180) < 0.001)
    #expect(abs(look.pitchDegrees) < 0.001)
}

@Test func quarterTurnFacesWest() {
    let look = ProtocolLook(tableFromDeviceRotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
    #expect(abs(look.yawDegrees - 90) < 0.001)
    #expect(abs(look.pitchDegrees) < 0.001)
}

@Test(arguments: [Float(-45), Float(45)]) func pitchUsesMinecraftSign(angle: Float) {
    let look = ProtocolLook(tableFromDeviceRotation: simd_quatf(angle: angle * .pi / 180, axis: [1, 0, 0]))
    #expect(abs(look.pitchDegrees + angle) < 0.001)
}

@Test func tablePoseUsesInverseThenDeviceWithoutReflection() {
    var originFromTable = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
    originFromTable.columns.3 = [1, 0.8, -0.75, 1]
    let frame = TableFrame(originFromTable: originFromTable)
    var tableFromDevice = simd_float4x4(simd_quatf(angle: .pi / 4, axis: [1, 0, 0]))
    tableFromDevice.columns.3 = [0.2, 0.3, -0.4, 1]
    let result = frame.tableFromDevice(originFromDevice: originFromTable * tableFromDevice)
    for index in 0..<4 {
        #expect(simd_length(result[index] - tableFromDevice[index]) < 0.00001)
        #expect(simd_length((frame.tableFromOrigin * originFromTable)[index] - matrix_identity_float4x4[index]) < 0.00001)
    }
}

@Test func inFrontPlacesTableAheadAndBelowLevelLook() {
    // Head 1.6 m up, turned 90° left (looking west, -X) and pitched down 30°.
    let turn = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]) * simd_quatf(angle: -.pi / 6, axis: [1, 0, 0])
    var originFromDevice = simd_float4x4(turn)
    originFromDevice.columns.3 = [0, 1.6, 0, 1]
    let table = TableFrame.inFront(of: originFromDevice).originFromTable
    #expect(simd_length(table.columns.3 - SIMD4<Float>(-0.75, 1.25, 0, 1)) < 0.0001)
    #expect(simd_length(table.columns.1 - SIMD4<Float>(0, 1, 0, 0)) < 0.0001)  // stays level
    #expect(simd_length(-table.columns.2 - SIMD4<Float>(-1, 0, 0, 0)) < 0.0001) // table -Z faces away from the user
}
