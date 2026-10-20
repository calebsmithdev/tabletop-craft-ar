import Foundation
import Testing
import TabletopCore
@testable import TabletopSpatial

@Suite struct M3EyeProbeTests {
    private func world(_ dims: SIMD3<Int>, _ palette: [String], _ fill: (Int,Int,Int) -> UInt16) -> WorldModel {
        var grid = [UInt16]()
        for y in 0..<dims.y { for z in 0..<dims.z { for x in 0..<dims.x { grid.append(fill(x,y,z)) } } }
        var world = WorldModel()
        world.load(ChunkSnapshot(snapshotId: 1, dims: dims, palette: palette, grid: grid))
        return world
    }

    @Test func movingHeadAndOutrunsPreserveWaterFadeAndVision() throws {
        let water = world([96,4,4],["minecraft:water"]) { _,_,_ in 0 }
        for blockSize: Float in [0.5/64,0.002] { for speed: Float in [0.002,0.006] {
            let probe = EyeProbe()
            var filter = EyeMediumFilter(), lastTicks: Float = 0
            for frame in 0..<40 {
                let block = SIMD3<Float>(30 + Float(frame % 20)*speed/blockSize,1.5,1.5)
                // 20 ms producer updates with a 6 mm head movement before render.
                probe.publishHead(block)
                probe.publish(world: water,blockSize: blockSize,center: .zero,generation: 1)
                let snapshot = try #require(probe.take(generation: 1))
                #expect(snapshot.neighborhood.radius == Int(min(16,(0.03/blockSize).rounded(.up))))
                let moved = block + SIMD3<Float>(speed/blockSize,0,0)
                #expect(snapshot.neighborhood.contains(moved))
                filter.update(snapshot.neighborhood,at: moved,blockSizeM: blockSize,dt: 0.02)
                if frame >= 3 {
                    #expect(filter.medium == .water && filter.look.visible)
                    #expect(filter.visionTicks > lastTicks)
                    let look = filter.look, ticks = filter.visionTicks
                    // An unusually long missed publication is still no observation.
                    filter.update(snapshot.neighborhood,at: moved+[40,0,0],blockSizeM: blockSize,dt: 0.02)
                    #expect(filter.medium == .water && filter.look == look && filter.visionTicks == ticks)
                    filter.update(nil,at: moved,blockSizeM: blockSize,dt: 0.02)
                    #expect(filter.look == look && filter.visionTicks == ticks)
                }
                lastTicks = filter.visionTicks
            }
            for _ in 0..<1500 { filter.update(water,[30,1.5,1.5],blockSize,0.02) }
            #expect(filter.visionTicks == 600 && filter.medium == .water)
            let look = filter.look
            filter.update(nil,at: .zero,blockSizeM: blockSize,dt: 0.02)
            #expect(filter.visionTicks == 600 && filter.look == look)
        } }
    }

    @Test func compactCellsMatchReferenceFluidsSlabsPowderAndMargins() {
        let states = ["minecraft:air", "minecraft:water[level=0]", "minecraft:water[level=7]",
                      "minecraft:lava[level=7]", "minecraft:oak_slab[type=bottom,waterlogged=true]",
                      "minecraft:oak_slab[type=top,waterlogged=true]", "minecraft:oak_slab[type=double]",
                      "minecraft:powder_snow", "minecraft:glass", "minecraft:stone",
                      "minecraft:water[level=8]", "minecraft:kelp", "minecraft:oak_stairs[waterlogged=true]"]
        var world = world([13,3,3], states) { x,y,_ in y < 2 ? UInt16(x) : 0 }
        world.applyShapeOverrides([states[12]: .model])
        var palette = EyeMediumPalette(); palette.update(world)
        let fractions: [Float] = [0, 0.1, Float(1)/9, 0.49, 0.5, 0.75, Float(8)/9, 0.95]
        for x in -1...13 { for y in 0...2 { for fraction in fractions {
            let position = SIMD3<Float>(Float(x)+0.5, Float(y)+fraction, 1.5)
            let neighborhood = EyeNeighborhood(world: world, palette: palette, head: position)
            #expect(neighborhood.contains(position))
            #expect(neighborhood.medium(at: position) == EyeMediumRules.at(world,position))
            for medium in [EyeMedium.air, .water, .lava, .solid, .powderSnow] {
                for margin: Float in [0.05, 0.4, 1] {
                    #expect(neighborhood.near(position,medium,margin) == EyeMediumRules.near(world,position,medium,margin))
                }
            }
        } } }
    }

    @Test func paletteParsesOnlyChangesIncludingReplacementAndShapeOverride() {
        let slab = "minecraft:oak_slab[type=bottom,waterlogged=true]"
        var world = world([1,1,1], [slab]) { _,_,_ in 0 }
        var palette = EyeMediumPalette(); palette.update(world)
        #expect(palette.computed == 1)
        palette.update(world); #expect(palette.computed == 1)
        var sample = EyeNeighborhood(world: world,palette: palette,head: .zero)
        #expect(sample.medium(at: [0.5,0.75,0.5]) == .water)
        world.applyShapeOverrides([slab: .cube]); palette.update(world)
        #expect(palette.computed == 2)
        sample = EyeNeighborhood(world: world,palette: palette,head: .zero)
        #expect(sample.medium(at: [0.5,0.75,0.5]) == .solid)
        world.load(ChunkSnapshot(snapshotId: 2,dims: [1,1,1],palette: ["minecraft:lava[level=0]"],grid: [0]))
        palette.update(world); #expect(palette.computed == 3)
        sample = EyeNeighborhood(world: world,palette: palette,head: .zero)
        #expect(sample.medium(at: [0.5,0.75,0.5]) == .lava)
    }

    @Test func compactFilterMatchesWorldColorsDwellFadeAndHysteresis() {
        var world = world([5,5,5], ["minecraft:air", "minecraft:water[level=0]"]) { _,y,_ in y < 4 ? 1 : 0 }
        world.tints = BiomeTints(BiomeGrid(qDims: [2,2,2],palette: ["minecraft:swamp","minecraft:cherry_grove"],
                                         cells: [0,1,0,1,0,1,0,1]), origin: .zero,dims: world.dims)
        var palette = EyeMediumPalette(); palette.update(world)
        var reference = EyeMediumFilter(), compact = EyeMediumFilter()
        for frame in 0..<700 {
            let p: SIMD3<Float> = frame < 650 ? [2,3.5,2] : frame < 675 ? [2,4.01,2] : [2,4.8,2]
            let sample = EyeNeighborhood(world: world,palette: palette,head: p)
            #expect(sample.waterColor(at: p) == EyeMediumRules.waterColor(world,p))
            #expect(compact.update(sample,p,0.01,0.02) == reference.update(world,p,0.01,0.02))
            #expect(compact.medium == reference.medium && compact.changed == reference.changed)
            #expect(compact.visionTicks == reference.visionTicks)
        }
        let untinted = self.world([1,1,1],["minecraft:water"]) { _,_,_ in 0 }
        palette.update(untinted)
        #expect(EyeNeighborhood(world: untinted,palette: palette,head: .zero).waterColor(at: .zero) == Rgb.hex(EyeMediumRules.defaultWaterColor))
    }

    @Test func snapshotsAndReaderDoNotRetainGridOrCauseCopyOnWrite() throws {
        var world = world([128,64,128],["minecraft:air","minecraft:water"]) { _,_,_ in 1 }
        let probe = EyeProbe()
        probe.publishHead([2.5,2.5,2.5])
        let address = world.grid.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) }
        probe.publish(world: world,blockSize: 0.02,center: .zero,generation: 1)
        let snapshot = try #require(probe.latest(generation: 1))
        var reader = EyeProbeReader()
        _ = reader.resolve(snapshot,visibleGeneration: 1)
        for index in 0..<12 {
            world.setLocal(2,2,2,UInt16(index % 2))
            probe.publish(world: world,blockSize: 0.02,center: .zero,generation: 1)
            #expect(world.grid.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) } == address)
        }
        // Held snapshots still own their old resolved values without sharing the grid.
        #expect(snapshot.neighborhood.medium(at: [2.5,2.5,2.5]) == .water)
        #expect(reader.resolve(nil,visibleGeneration: 1)?.neighborhood.medium(at: [2.5,2.5,2.5]) == .water)
        #expect(reader.resolve(nil,visibleGeneration: 2) == nil)
    }

    @Test func mailboxStaysBoundedWithoutRendererAndPreservesDisplayedGeneration() throws {
        let water = world([1,1,1],["minecraft:water"]) { _,_,_ in 0 }
        let lava = world([1,1,1],["minecraft:lava"]) { _,_,_ in 0 }
        let unattended = EyeProbe()
        for generation in UInt64(1)...1000 {
            unattended.publish(world: water,blockSize: 0.02,center: .zero,generation: generation)
            // Republish the same generation as the session drive loop does.
            unattended.publish(world: water,blockSize: 0.02,center: .zero,generation: generation)
            #expect(unattended.retainedSnapshotCount <= 2)
        }
        #expect(unattended.retainedSnapshotCount == 2)
        #expect(unattended.latest(generation: 998) == nil)
        #expect(unattended.latest(generation: 999)?.generation == 999)
        #expect(unattended.latest(generation: 1000)?.generation == 1000)

        let displayed = EyeProbe()
        displayed.publish(world: water,blockSize: 0.02,center: .zero,generation: 1)
        #expect(displayed.latest(generation: 1)?.generation == 1)
        for generation in UInt64(2)...1001 {
            displayed.publish(world: lava,blockSize: 0.04,center: .zero,generation: generation)
            #expect(displayed.retainedSnapshotCount == 2)
        }
        let retained = try #require(displayed.latest(generation: 1))
        #expect(retained.blockSize == 0.02)
        #expect(retained.neighborhood.medium(at: [0.5,0.5,0.5]) == .water)
        #expect(displayed.latest(generation: 1000) == nil)
        #expect(displayed.latest(generation: 1001)?.neighborhood.medium(at: [0.5,0.5,0.5]) == .lava)
        // Pruning remains producer-owned after the displayed generation advances.
        displayed.publish(world: lava,blockSize: 0.04,center: .zero,generation: 1001)
        #expect(displayed.retainedSnapshotCount == 1)
        #expect(displayed.latest(generation: 1) == nil)
    }

    @Test func headRefreshGenerationStagingAndBounds() throws {
        let water = world([20,3,3],["minecraft:water"]) { _,_,_ in 0 }
        let lava = world([20,3,3],["minecraft:lava"]) { _,_,_ in 0 }
        let probe = EyeProbe()
        probe.setHead([0.05,0.01,0.01])
        probe.publish(world: water,blockSize: 0.02,center: .zero,generation: 1)
        let first = try #require(probe.take(generation: 1))
        #expect(first.neighborhood.contains([2.5,0.5,0.5]))
        #expect(first.neighborhood.medium(at: [2.5,0.5,0.5]) == .water)
        probe.setHead([0.25,0.01,0.01])
        // An unchanged world must still be republished after head movement.
        #expect(!first.neighborhood.contains([12.5,0.5,0.5]))
        probe.publish(world: water,blockSize: 0.02,center: .zero,generation: 1)
        let refreshed = try #require(probe.latest(generation: 1))
        #expect(refreshed.neighborhood.contains([12.5,0.5,0.5]))
        probe.publish(world: lava,blockSize: 0.04,center: [1,0,0],generation: 2)
        let displayed = try #require(probe.latest(generation: 1))
        #expect(displayed.blockSize == 0.02 && displayed.center == .zero)
        #expect(displayed.neighborhood.medium(at: [12.5,0.5,0.5]) == .water)
        var reader = EyeProbeReader()
        _ = reader.resolve(displayed,visibleGeneration: 1)
        let staged = try #require(probe.latest(generation: 2))
        #expect(staged.neighborhood.contains([7.25,0.25,0.25]))
        #expect(staged.neighborhood.medium(at: [7.25,0.25,0.25]) == .lava)
        #expect(reader.resolve(staged,visibleGeneration: 1)?.generation == 1)
        #expect(reader.resolve(staged,visibleGeneration: 2)?.generation == 2)
        #expect(reader.resolve(nil,visibleGeneration: nil) == nil)
        probe.publish(world: lava,blockSize: 0.04,center: [1,0,0],generation: 2)
        #expect(probe.latest(generation: 1) == nil)
        #expect(probe.latest(generation: 3) == nil)
        #expect(!staged.neighborhood.contains([.nan,0,0]))
        #expect(!staged.neighborhood.contains([.infinity,0,0]))
        #expect(staged.neighborhood.medium(at: [Float.greatestFiniteMagnitude,0,0]) == .air)
    }
}
