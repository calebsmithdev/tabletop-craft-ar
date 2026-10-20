import Foundation
import Metal
import Testing
import TabletopCore
@testable import TabletopRender

@Suite struct GenerationLifecycleTests {
    @Test func inactiveDoesNotReconnectAndBackgroundResumesOnlyOnce() {
        var lifecycle = ConnectionLifecycle()
        // Initial activation, then any number of inactive/active transitions.
        let resumed0 = lifecycle.resume(wantsConnection: true)
        #expect(!resumed0)
        let resumed1 = lifecycle.resume(wantsConnection: true)
        #expect(!resumed1)
        lifecycle.pause(wantsConnection: true)
        #expect(lifecycle.pausedForBackground)
        let resumed2 = lifecycle.resume(wantsConnection: true)
        #expect(resumed2)
        let resumed3 = lifecycle.resume(wantsConnection: true)
        #expect(!resumed3)
        lifecycle.pause(wantsConnection: true)
        lifecycle.cancelPause() // Explicit disconnect while backgrounded.
        let resumed4 = lifecycle.resume(wantsConnection: false)
        #expect(!resumed4)
        lifecycle.pause(wantsConnection: false)
        let resumed5 = lifecycle.resume(wantsConnection: true)
        #expect(!resumed5)
    }

    @Test func liveUpdateRevokesPendingGenerationReadiness() async throws {
        let queue = DispatchQueue(label: "test.generation-preparation")
        let scene = BatchScene(preparationQueue: queue), key = SIMD3<Int>.zero
        // Seed visible content so this exercises replacement staging, not first load.
        scene.publish(BatchUpload(generation: 0, key: key, data: BatchData.assemble([]), position: .zero, blockSize: 0.01, center: .zero))
        let mailbox = try scene.attach(device: #require(MTLCreateSystemDefaultDevice()))
        let initialDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < initialDeadline {
            let reopened = try scene.attach(device: #require(MTLCreateSystemDefaultDevice()))
            if case .replace(_, let batches) = reopened.next(generation: nil), batches.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        queue.sync {} // Drain the running worker before suspending future preparation.
        queue.suspend()
        do {
            defer { queue.resume() }
            scene.beginGeneration(1)
            scene.publish(BatchUpload(generation: 1, key: key, data: BatchData.assemble([]), position: .zero, blockSize: 0.01, center: .zero))
            scene.completeGeneration(1) // GPU preparation is held until readiness is revoked.
            #expect(scene.invalidateCompletion(1))
            try await Task.sleep(for: .milliseconds(30))
            if case .replace(let generation, let drawn) = mailbox.next(generation: nil) {
                #expect(generation == 0 && drawn.count == 1)
            } else { Issue.record("expected the previous visible generation") }
            let incomplete = mailbox.next(generation: 0)
            if incomplete != nil { Issue.record("incomplete generation became visible") }
            scene.publish(BatchUpload(generation: 1, key: key, data: BatchData.assemble([]), position: [10,0,0], blockSize: 0.01, center: .zero))
            scene.completeGeneration(1)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if case .replace(let generation, let drawn) = mailbox.next(generation: 0) {
                #expect(generation == 1)
                #expect(abs((drawn[key]?.boundsMin.x ?? 0) - 0.1) < 0.0001)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("updated generation did not complete")
    }


    @Test func firstGenerationPublishesBeforeCompletionAndReplacementWaits() async throws {
        let scene = BatchScene(), device = try #require(MTLCreateSystemDefaultDevice())
        let mailbox = try scene.attach(device: device)
        scene.beginGeneration(1)
        scene.publish(BatchUpload(generation: 1, key: .zero, data: BatchData.assemble([]),
                                  position: .zero, blockSize: 0.01, center: .zero))
        var visible: UInt64?
        var count = 0
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let update = mailbox.next(generation: visible) {
                switch update {
                case .replace(let generation, let batches): visible = generation; count = batches.count
                case .batch: count += 1
                }
            }
            if visible == 1 && count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(visible == 1 && count == 1) // No completeGeneration call yet.
        scene.completeGeneration(1)
        scene.beginGeneration(2)
        scene.publish(BatchUpload(generation: 2, key: [1,0,0], data: BatchData.assemble([]),
                                  position: .zero, blockSize: 0.01, center: .zero))
        try await Task.sleep(for: .milliseconds(30))
        let reopened = try scene.attach(device: device)
        if case .replace(let generation, let batches) = reopened.next(generation: nil) {
            #expect(generation == 1 && batches[.zero] != nil && batches.count == 1)
        } else { Issue.record("expected visible first generation during replacement") }
    }

    @Test func failedStagedRevisionResolvesAndLivePublishRetries() async throws {
        let scene = BatchScene(), device = try #require(MTLCreateSystemDefaultDevice())
        var world = WorldModel()
        world.load(ChunkSnapshot(snapshotId: 1, dims: [1,1,1], palette: ["minecraft:stone"], grid: [0]))
        var geometry = MeshData(); GreedyMesher.build(world, .zero, &geometry)
        let mesh = try #require(SectionMesh.from(geometry, .zero))
        let data = BatchData.assemble([(mesh: mesh, offset: .zero)])
        func publish(_ generation: UInt64, _ key: Int, size: Float = 0.01) {
            scene.publish(BatchUpload(generation: generation, key: [key,0,0], data: data,
                                      position: .zero, blockSize: size, center: .zero))
        }
        let mailbox = try scene.attach(device: device)
        var visible: UInt64?
        var drawn: [SIMD3<Int>: PreparedBatch] = [:]
        func waitFor(_ generation: UInt64, keys: Set<SIMD3<Int>>) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                while let update = mailbox.next(generation: visible) {
                    switch update {
                    case .replace(let current, let batches): visible = current; drawn = batches
                    case .batch(let batch): drawn[batch.key] = batch
                    }
                }
                if visible == generation, Set(drawn.keys) == keys,
                   drawn.values.allSatisfy({ $0.indexCount > 0 }) { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("expected generation and prepared keys did not appear")
        }
        publish(1, 0)
        try await waitFor(1, keys: [[0,0,0]])
        scene.beginGeneration(2)
        publish(2, 1)
        publish(2, 2, size: .nan)
        scene.completeGeneration(2)
        // Attachments can requeue in-flight revisions; draining those duplicates
        // must still commit without another attachment or completion call.
        let otherConsumer = try scene.attach(device: device)
        try await waitFor(2, keys: [[1,0,0]])
        withExtendedLifetime(otherConsumer) {}
        #expect(scene.preparationFailureCount == 1)
        // Renderer reattachments must not retry or log the same failed revision.
        _ = try scene.attach(device: device)
        try await Task.sleep(for: .milliseconds(30))
        #expect(scene.preparationFailureCount == 1)
        publish(2, 1)
        publish(2, 2)
        try await waitFor(2, keys: [[1,0,0], [2,0,0]])
        #expect(scene.preparationFailureCount == 1)
    }

    @Test func replacementIsAtomicAndSupersededGenerationNeverAppears() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = BatchScene()
        let mailbox = try scene.attach(device: device)
        var generation: UInt64?
        var drawn: [SIMD3<Int>: PreparedBatch] = [:]
        func consume() {
            while let update = mailbox.next(generation: generation) {
                switch update {
                case .replace(let next, let replacement): generation = next; drawn = replacement
                case .batch(let batch): drawn[batch.key] = batch
                }
            }
        }
        var world = WorldModel()
        world.load(ChunkSnapshot(snapshotId: 1, dims: [1,1,1], palette: ["minecraft:stone"], grid: [0]))
        var geometry = MeshData()
        GreedyMesher.build(world, .zero, &geometry)
        let mesh = try #require(SectionMesh.from(geometry, .zero))
        let data = BatchData.assemble([(mesh: mesh, offset: .zero)])
        func upload(_ generation: UInt64, _ key: Int) -> BatchUpload {
            BatchUpload(generation: generation, key: [key,0,0], data: data,
                        position: .zero, blockSize: 0.01, center: .zero)
        }
        func waitFor(_ expected: UInt64, count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                consume()
                if generation == expected && drawn.count == count { return }
                try await Task.sleep(for: .milliseconds(5))
            } while ContinuousClock.now < deadline
            Issue.record("generation did not become ready")
        }
        scene.reset(generation: 1)
        scene.publish(upload(1, 1))
        try await waitFor(1, count: 1)
        #expect(drawn.values.allSatisfy { $0.indexCount > 0 && $0.vertices != nil && $0.indices != nil })
        scene.beginGeneration(2)
        scene.publish(upload(2, 2))
        try await Task.sleep(for: .milliseconds(30))
        consume()
        #expect(generation == 1 && Set(drawn.keys) == [[1,0,0]])
        // Supersede a prepared but incomplete generation.
        scene.beginGeneration(3)
        scene.publish(upload(3, 3))
        scene.completeGeneration(2)
        scene.publish(upload(2, 4))
        try await Task.sleep(for: .milliseconds(30))
        consume()
        #expect(generation == 1 && Set(drawn.keys) == [[1,0,0]])
        scene.publish(upload(3, 4))
        scene.completeGeneration(3)
        try await waitFor(3, count: 2)
        #expect(Set(drawn.keys) == [[3,0,0], [4,0,0]])
        #expect(drawn.values.allSatisfy { $0.generation == 3 && $0.indexCount > 0 })
        // Reopening a renderer sees the complete generation in one mailbox update.
        let reopened = try scene.attach(device: device)
        if case .replace(let current, let batches) = reopened.next(generation: nil) {
            #expect(current == 3 && batches.count == 2)
        } else { Issue.record("expected atomic replacement on reopen") }
    }
}
