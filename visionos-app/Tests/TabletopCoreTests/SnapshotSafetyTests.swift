import Foundation
import Testing
@testable import TabletopCore

struct SnapshotSafetyTests {
    private func snapshot(_ dims: Int3 = [1,1,1], count: Int = 1) -> JSONObject {
        ["type": "chunk_snapshot", "snapshot_id": 1, "world": "world", "origin": [0,0,0],
         "dims": Protocol.vector(dims), "order": "yzx", "encoding": "rle_palette_v1",
         "palette": ["minecraft:air"], "data": [0,.number(Double(count))]]
    }

    private func sectioned(_ dims: Int3 = [1,1,1], count: Int = 1) -> JSONObject {
        var m = snapshot(dims,count: count)
        m["encoding"] = "sections_v1"; m["part"] = 0; m["parts"] = 1
        m["sections"] = [["s": [0,0,0], "data": [0,.number(Double(count))]]]
        return m
    }

    private func biome(_ dims: Int3, count: Int) -> JSONObject {
        ["res": 4, "encoding": "rle_palette_v1", "q_origin": [0,0,0],
         "q_dims": Protocol.vector(dims), "palette": ["minecraft:plains"],
         "data": [0,.number(Double(count))]]
    }

    @Test func dimensionsRejectNonpositiveOverflowAndOversizedVolumes() throws {
        let invalid: [Int3] = [[0,1,1], [-1,1,1], [1,0,1], [1,1,-1],
                               [4_294_967_296,4_294_967_296,2], [1000,100,1000]]
        for dims in invalid {
            #expect(throws: (any Error).self) { try ChunkSnapshot.from(snapshot(dims)) }
            #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([sectioned(dims)]) }
            #expect(throws: (any Error).self) { try BiomeGrid.from(biome(dims,count: 1)) }
        }
        var malformed = snapshot(); malformed["dims"] = [0,2147483647]
        #expect(throws: (any Error).self) { try ChunkSnapshot.from(malformed) }
        #expect(try SnapshotFields.volume([352,384,352]) == SnapshotLimits.hardMaxBlocks)
        #expect(throws: (any Error).self) { try SnapshotFields.volume([353,384,352]) }
    }

    @Test func giantRunsRejectBeforeAllocationForBlocksLightAndBiomes() throws {
        let runs: [JSONValue] = [0,2147483647]
        var full = snapshot(); full["data"] = .array(runs)
        #expect(throws: (any Error).self) { try ChunkSnapshot.from(full) }
        #expect(throws: (any Error).self) { try ChunkSnapshot.decodeRle(runs,2147483647,1) }
        #expect(throws: (any Error).self) {
            try ChunkSnapshot.decodeLight(["encoding": "rle_v1", "data": .array(runs)],2147483647)
        }
        var sections = sectioned()
        sections["sections"] = [["s": [0,0,0], "data": .array(runs)]]
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([sections]) }
        sections = sectioned(); sections["light"] = ["encoding": "rle_v1", "in_sections": true]
        sections["sections"] = [["s": [0,0,0], "data": [0,1], "light": .array(runs)]]
        #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([sections]) }
        #expect(throws: (any Error).self) { try BiomeGrid.from(biome([1,1,1],count: 2147483647)) }
        #expect(throws: (any Error).self) { try ChunkSnapshot.decodeRle([],0,1) }
    }

    @Test func explicitAllocationCeilingsApplyToAllDecoders() throws {
        let ceiling = 10
        #expect(try ChunkSnapshot.from(snapshot([10,1,1],count: 10),maxBlocks: ceiling).grid.count == 10)
        #expect(throws: (any Error).self) {
            try ChunkSnapshot.from(snapshot([11,1,1],count: 11),maxBlocks: ceiling)
        }
        #expect(throws: (any Error).self) {
            try SectionedSnapshot.assemble([sectioned([11,1,1],count: 11)],maxBlocks: ceiling)
        }
        #expect(throws: (any Error).self) {
            try ChunkSnapshot.decodeLight(["encoding": "rle_v1", "data": [0,11]],11,maxBlocks: ceiling)
        }
        #expect(throws: (any Error).self) {
            try BiomeGrid.from(biome([11,1,1],count: 11),maxBlocks: ceiling)
        }
        for isSectioned in [false,true] {
            var m = isSectioned ? sectioned() : snapshot()
            m["biomes"] = .object(biome([11,1,1],count: 11))
            if isSectioned {
                #expect(throws: (any Error).self) { try SectionedSnapshot.assemble([m],maxBlocks: ceiling) }
            } else {
                #expect(throws: (any Error).self) { try ChunkSnapshot.from(m,maxBlocks: ceiling) }
            }
        }
        #expect(throws: (any Error).self) {
            try ChunkSnapshot.decodeRle([0,.number(Double(SnapshotLimits.hardMaxBlocks + 1))],
                                       SnapshotLimits.hardMaxBlocks + 1,1,maxBlocks: Int.max)
        }
    }

    @Test func advertisedLimitHasBoundedHeadroomAndCanBeUpdated() throws {
        #expect(SnapshotLimits.allocationLimit(for: nil) == 352 * 384 * 352)
        #expect(SnapshotLimits.allocationLimit(for: 8) == 10)
        #expect(SnapshotLimits.allocationLimit(for: Int.max) == SnapshotLimits.hardMaxBlocks)
        #expect(SnapshotLimits.allocationLimit(for: 0) == 0)
        #expect(SnapshotLimits.allocationLimit(for: -1) == 0)
        for isSectioned in [false,true] {
            var assembler = SnapshotAssembler(maxBlocks: 8)
            let allowed = isSectioned ? sectioned([10,1,1],count: 10) : snapshot([10,1,1],count: 10)
            let rejected = isSectioned ? sectioned([11,1,1],count: 11) : snapshot([11,1,1],count: 11)
            try assembler.offer(allowed,WorldModel())
            #expect(assembler.wait()?.snapshot?.grid.count == 10)
            try assembler.offer(rejected,WorldModel())
            #expect(assembler.wait()?.error != nil)
            assembler.maxBlocks = 12
            try assembler.offer(rejected,WorldModel())
            #expect(assembler.wait()?.snapshot?.grid.count == 11)
            assembler.maxBlocks = 0
            try assembler.offer(snapshot(),WorldModel())
            #expect(assembler.wait()?.error != nil)
        }
    }

    @Test func oversizedMultipartIsRejectedBeforeItIsBuffered() throws {
        var assembler = SnapshotAssembler(maxBlocks: 8)
        var first = sectioned([11,1,1],count: 11); first["parts"] = 2
        try assembler.offer(first,WorldModel())
        #expect(assembler.partsWaiting == 0)
        let pending = assembler.wait()
        let rejected = try #require(pending)
        #expect(rejected.error != nil && rejected.snapshot == nil)
        try assembler.offer(sectioned(),WorldModel())
        #expect(assembler.wait()?.snapshot?.grid == [0])
    }

    @Test func maliciousPartCountRejectsBeforeBufferingAndCanRecover() throws {
        var assembler = SnapshotAssembler()
        for (dims, total) in [(Int3(1,1,1), Int.max / 2), (Int3(17,17,17), 9)] {
            var malicious = sectioned(dims)
            malicious["parts"] = .number(Double(total))
            try assembler.offer(malicious, WorldModel())
            #expect(assembler.partsWaiting == 0)
            let pending = assembler.tryTake()
            let result = try #require(pending)
            #expect(result.error != nil && result.snapshot == nil)
        }
        var missingDims = sectioned(); missingDims.removeValue(forKey: "dims")
        missingDims["parts"] = 1000000
        try assembler.offer(missingDims, WorldModel())
        let missingResult = assembler.tryTake()
        #expect(assembler.partsWaiting == 0 && missingResult?.error != nil)
        try assembler.offer(sectioned(), WorldModel())
        let recovered = assembler.tryTake()
        #expect(recovered?.snapshot?.grid == [0])
    }

    @Test func sectionPlanningDefaultsOffAndOptInStillCompares() throws {
        let full = snapshot([2,1,1],count: 2)
        var world = WorldModel(); world.applySnapshot(try ChunkSnapshot.from(full))
        var defaultAssembler = SnapshotAssembler()
        try defaultAssembler.offer(full,world)
        let defaultResult = defaultAssembler.wait()
        let skipped = try #require(defaultResult)
        #expect(skipped.snapshot?.grid == [0,0] && skipped.plan == nil)
        var plannedAssembler = SnapshotAssembler(computeSectionPlan: true)
        try plannedAssembler.offer(full,world)
        let plannedResult = plannedAssembler.wait()
        let planned = try #require(plannedResult?.plan)
        #expect(planned.rekey && planned.compared == 2 && planned.kept == 1 && planned.mesh.isEmpty)
    }

    @Test func integralDoublesUseIntegerTokensAndFractionsRoundTrip() throws {
        let integers: [(Double,String)] = [(0,"0"), (-0.0,"0"), (1,"1"), (-1,"-1"),
            (Double(UInt32.max),"4294967295"), (1_760_370_003_000,"1760370003000"),
            (9_007_199_254_740_991,"9007199254740991"), (-9_007_199_254_740_991,"-9007199254740991")]
        for (value,token) in integers {
            #expect(try Json.stringify(.number(value)) == token)
        }
        let fractions: [Double] = [0.1, -0.000123456789012345, Double.leastNonzeroMagnitude,
            Double.greatestFiniteMagnitude, 1.0000000000000002, 9_007_199_254_740_992]
        for value in fractions {
            let token = try Json.stringify(.number(value))
            #expect(token == String(value))
            #expect(try Json.parse(token) == .number(value))
        }
    }

    @Test func helloAndPoseEnvelopesUseIntegerVersionAndSequenceTokens() throws {
        var envelope = Envelope(nextSeq: .max)
        let hello = try Json.stringify(envelope.wrap(Protocol.hello(),t: 1_760_370_003_000))
        #expect(hello.contains(#""v":1}"#))
        #expect(hello.contains(#""seq":4294967295,"#))
        #expect(hello.contains(#""protocols":[1]"#))
        #expect(hello.contains(#""t":1760370003000,"#))
        let pose = try Json.stringify(envelope.wrap(Protocol.pose(123456789,head: TabletopPose()),t: 10))
        #expect(pose.contains(#""v":1}"#) && pose.contains(#""seq":0,"#))
        #expect(pose.contains(#""ts":123456789,"#))
    }

    @Test func helloAndPoseFixturesRetainTheirIntegerWireFields() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/fixtures")
        for name in ["hello", "hello_pair", "pose"] {
            let source = try String(contentsOf: fixtures.appendingPathComponent(name + ".json"),encoding: .utf8)
            let value = try Json.parse(source), m = try #require(value.objectValue)
            let wire = try Json.stringify(value)
            #expect(try Json.parse(wire) == value)
            #expect(wire.contains("\"v\":1}"))
            #expect(wire.contains("\"seq\":\(m.i("seq")),"))
        }
    }
}
