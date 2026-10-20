import Foundation
import Testing
import TabletopCore
import TabletopSpatial
import TabletopRender

@Suite struct M3bSessionTests {
    @Test func renderingPreferencesPersistWithQuestDefaultsAndClamps() throws {
        let defaults = AppPrefs()
        #expect(defaults.mipmaps && defaults.smoothLighting && defaults.leavesInner)
        #expect(defaults.minLight == 0.2 && defaults.brightness == 1 && defaults.meshWorkers == 3)
        var prefs = defaults
        prefs.mipmaps = false; prefs.smoothLighting = false; prefs.leavesInner = false
        prefs.minLight = 0.45; prefs.brightness = 0.6; prefs.meshWorkers = 5; prefs.manualPack = true
        let restored = try AppPrefs.parse(prefs.toJson())
        #expect(!restored.mipmaps && !restored.smoothLighting && !restored.leavesInner)
        #expect(restored.minLight == 0.45 && restored.brightness == 0.6 && restored.meshWorkers == 5)
        #expect(restored.manualPack)
        let clamped = try AppPrefs.parse(#"{"min_light":-8,"brightness":9,"mesh_workers":99}"#)
        #expect(clamped.minLight == -1 && clamped.brightness == 1 && clamped.meshWorkers == 8)
        #expect(Protocol.hello().a("caps")?.contains(.string("assets_v1")) == true)
    }

    @Test func importedPackIsInstalledAndInvalidImportPreservesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try atlasZip(atlasFluidEntries())
        defer { try? FileManager.default.removeItem(at: source) }
        let session = WorldSession(scene: BatchScene(), assetDirectory: directory)
        #expect(await session.importPack(source))
        let destination = directory.appendingPathComponent("pack.zip")
        let before = try Data(contentsOf: destination)
        #expect(before == (try Data(contentsOf: source)))
        #expect((await session.latest()).pack.contains("pack.zip"))
        let invalid = directory.appendingPathComponent("invalid.zip")
        try Data("invalid archive".utf8).write(to: invalid)
        #expect(await !session.importPack(invalid))
        #expect(try Data(contentsOf: destination) == before)
        #expect((await session.latest()).pack.contains("Import error"))
    }

    @Test func probeReaderDropsUnderwaterWorldOnResetButRetainsDuringContention() throws {
        let probe = EyeProbe()
        var world = WorldModel()
        world.load(ChunkSnapshot(snapshotId: 1, dims: [1,1,1], palette: ["minecraft:water[level=0]"], grid: [0]))
        probe.publish(world: world, blockSize: 0.02, center: .zero, generation: 1)
        var reader = EyeProbeReader()
        let resolved = reader.resolve(probe.latest(generation: 1), visibleGeneration: 1)
        let first = try #require(resolved)
        #expect(first.neighborhood.medium(at: [0.5,0.5,0.5]) == .water)
        #expect(reader.resolve(nil, visibleGeneration: 1)?.generation == 1)
        #expect(reader.resolve(nil, visibleGeneration: 2) == nil)
        #expect(reader.resolve(probe.latest(generation: 1), visibleGeneration: 2) == nil)
        #expect(reader.resolve(nil, visibleGeneration: nil) == nil)
    }

    @Test func eyeProbeKeepsDisplayedGenerationWhileReplacementStages() throws {
        let probe = EyeProbe()
        var first = WorldModel()
        first.load(try ChunkSnapshot.from([
            "type": "chunk_snapshot", "snapshot_id": 1, "world": "test", "origin": [0,0,0], "dims": [1,1,1],
            "palette": ["minecraft:water[level=0]"], "encoding": "rle_palette_v1", "order": "yzx", "data": [0,1]
        ]))
        probe.publish(world: first, blockSize: 0.02, center: .zero, generation: 1)
        var next = first
        next.setLocal(0,0,0,0)
        probe.publish(world: next, blockSize: 0.04, center: [2,0,0], generation: 2)
        let old = try #require(probe.latest(generation: 1))
        #expect(old.blockSize == 0.02 && old.center == .zero)
        #expect(old.neighborhood.medium(at: [0.5,0.5,0.5]) == .water)
        #expect(probe.latest(generation: 3) == nil)
        let replacement = try #require(probe.latest(generation: 2))
        #expect(replacement.blockSize == 0.04 && replacement.center == [2,0,0])
        // Subsequent owner publication prunes obsolete snapshots off the render path.
        probe.publish(world: next, blockSize: 0.04, center: .zero, generation: 2)
        #expect(probe.latest(generation: 1) == nil)
        probe.publishHead([1,2,3])
        #expect(probe.latestHead == [1,2,3])
    }
}
