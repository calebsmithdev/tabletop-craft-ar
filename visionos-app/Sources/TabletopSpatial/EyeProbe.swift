#if canImport(Metal)
import Synchronization
import TabletopCore

/// The world owner publishes bounded, immutable neighborhoods. Neither this
/// mailbox nor its reader retains a WorldModel or any world-sized buffer.
/// A busy publication keeps the last probe for this frame without blocking.
public final class EyeProbe: Sendable {
    public struct Snapshot: Sendable {
        public let neighborhood: EyeNeighborhood
        public let blockSize: Float
        public let center: SIMD3<Float>
        public let generation: UInt64
    }
    private struct State: Sendable {
        var snapshots: [UInt64: Snapshot] = [:]
        var acknowledged: UInt64?
        var palette = EyeMediumPalette()
    }
    private struct Head: Sendable {
        var position = SIMD3<Float>.zero
        var tableSpace = false
    }
    private let state = Mutex(State())
    private let head = Mutex(Head())
    public init() {}
    /// Invoke on the session actor after world changes and on each drive tick,
    /// even when no network update arrived: the head can move through a static world.
    public func publish(world: WorldModel, blockSize: Float, center: SIMD3<Float>, generation: UInt64) {
        let head = head.withLock { $0 }
        let position = head.tableSpace ? head.position / max(blockSize, 0.0001) + center : head.position
        state.withLock { state in
            state.palette.update(world)
            let radius = Int(min(16,max(1,(0.03 / max(0.0001,blockSize)).rounded(.up))))
            let neighborhood = EyeNeighborhood(world: world, palette: state.palette, head: position, radius: radius)
            state.snapshots[generation] = Snapshot(neighborhood: neighborhood, blockSize: blockSize, center: center, generation: generation)
            let newest = state.snapshots.keys.max()
            // Keep the displayed generation through arbitrarily many staged
            // replacements. Before the renderer first acknowledges anything,
            // retain only the two newest generations, including repeated publishes.
            let retained = state.acknowledged ?? state.snapshots.keys.filter { $0 != newest }.max()
            state.snapshots = state.snapshots.filter { $0.key == newest || $0.key == retained }
        }
    }
    public func take(generation: UInt64) -> Snapshot? {
        state.withLockIfAvailable { state in
            guard let snapshot = state.snapshots[generation] else { return nil }
            state.acknowledged = max(state.acknowledged ?? generation, generation)
            return snapshot
        } ?? nil
    }
    public func latest(generation: UInt64) -> Snapshot? { take(generation: generation) }
    /// Internal diagnostic for bounded mailbox regression tests.
    var retainedSnapshotCount: Int { state.withLock { $0.snapshots.count } }
    /// Table-space meters survive a staged generation's changed block size/center.
    /// The publisher converts to the new generation's block coordinates.
    public func setHead(_ position: SIMD3<Float>) {
        head.withLockIfAvailable { $0 = Head(position: position, tableSpace: true) }
    }
    /// Compatibility for CPU callers that already have block coordinates.
    public func publishHead(_ position: SIMD3<Float>) {
        head.withLockIfAvailable { $0 = Head(position: position, tableSpace: false) }
    }
    /// Last supplied head in the coordinate space of setHead/publishHead.
    public var latestHead: SIMD3<Float>? { head.withLockIfAvailable { $0.position } }
}

/// Keeps a cached value only while it still describes the displayed scene.
/// A busy producer may miss one frame; a reset must never keep its old medium.
public struct EyeProbeReader: Sendable {
    private var cached: EyeProbe.Snapshot?
    public init() {}
    public mutating func resolve(_ incoming: EyeProbe.Snapshot?, visibleGeneration: UInt64?) -> EyeProbe.Snapshot? {
        if let incoming, incoming.generation == visibleGeneration { cached = incoming }
        if cached?.generation != visibleGeneration { cached = nil }
        return cached
    }
}
#endif
