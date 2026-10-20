import Foundation
import Synchronization
import OSLog
import TabletopCore
import simd
#if canImport(Metal)
import Metal
#endif

/// All positions are in blocks. Table metres = (vertex + position - center) * blockSize.
public struct BatchUpload: Sendable {
    public let generation: UInt64
    public let key: SIMD3<Int>
    public let data: BatchData
    public let position: SIMD3<Float>
    public let blockSize: Float
    public let center: SIMD3<Float>
    public let cellOrigin: SIMD3<Int>

    public init(generation: UInt64, key: SIMD3<Int>, data: BatchData,
                position: SIMD3<Float>, blockSize: Float, center: SIMD3<Float>, cellOrigin: SIMD3<Int> = .zero) {
        self.generation = generation
        self.key = key
        self.data = data
        self.position = position
        self.blockSize = blockSize
        self.center = center
        self.cellOrigin = cellOrigin
    }
}

#if canImport(Metal)
/// Retained independently of an immersive renderer. Only the preparation queue
/// packs arrays or creates buffers; the render thread takes completed references.
public final class BatchScene: Sendable {
    public struct Snapshot: Sendable {
        public let generation: UInt64
        public let batches: [SIMD3<Int>: BatchUpload]
    }

    private struct Entry: Sendable {
        let revision: UInt64
        let upload: BatchUpload
    }
    private struct WeakMailbox: Sendable {
        weak var value: BatchMailbox?
    }
    private struct State: Sendable {
        var generation: UInt64 = 0
        var visibleGeneration: UInt64 = 0
        var visibleGPU: [SIMD3<Int>: PreparedBatch] = [:]
        var packSource: BakedResourcePack?
        var pack: PreparedPack?
        var visiblePack: PreparedPack?
        var packRevision: UInt64 = 0
        var packReady = true
        var preparationError: String?
        var mipmaps = true
        var staging = false
        var completionRequested = false
        var revision: UInt64 = 0
        var cpu: [SIMD3<Int>: Entry] = [:]
        var pending: [SIMD3<Int>: Entry] = [:]
        var gpu: [SIMD3<Int>: PreparedBatch] = [:]
        var failed: [SIMD3<Int>: UInt64] = [:]
        var consumers: [WeakMailbox] = []
        var device: (any MTLDevice)?
        var scheduled = false
        var failures = 0
    }
    private let log = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "batch-preparation")
    private let state = Mutex(State())
    private let worker: DispatchQueue

    public init() {
        worker = DispatchQueue(label: "com.tabletopcraft.batch-preparation", qos: .userInitiated)
    }

    // Internal scheduling seam for deterministic preparation/readiness tests.
    init(preparationQueue: DispatchQueue) { worker = preparationQueue }

    /// Generations are monotonically increasing. Older asynchronous results are ignored.
    public func reset(generation: UInt64) {
        state.withLock { state in
            guard generation >= state.generation else { return }
            state.generation = generation
            state.visibleGeneration = generation
            state.visibleGPU.removeAll()
            state.visiblePack = state.packReady ? state.pack : nil
            state.staging = false
            state.completionRequested = false
            state.cpu.removeAll()
            state.pending.removeAll()
            state.gpu.removeAll()
            state.failed.removeAll()
            state.consumers.removeAll { $0.value == nil }
            for consumer in state.consumers { consumer.value?.reset(generation: generation, pack: state.visiblePack) }
        }
    }

    /// Stage replacements while visible content remains drawn; empty scenes load progressively.
    public func beginGeneration(_ generation: UInt64) {
        beginGeneration(generation, replacingPack: false, pack: nil)
    }

    /// nil explicitly selects the flat fallback. The old atlas stays with old
    /// staged meshes until all replacements and the new GPU atlas are ready.
    public func beginGeneration(_ generation: UInt64, pack: BakedResourcePack?) {
        beginGeneration(generation, replacingPack: true, pack: pack)
    }

    /// Append layers from the session-owned atlas without changing the mesh generation.
    /// Call before publishing geometry that references the new palette. Existing
    /// draws remain visible until preparation finishes, including capacity growth.
    public func updatePack(_ pack: BakedResourcePack, generation: UInt64) {
        let schedule = state.withLock { state in
            guard generation == state.generation else { return false }
            state.packRevision &+= 1
            state.packSource = pack
            state.packReady = false
            state.preparationError = nil
            guard state.device != nil, !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { worker.async { self.preparePending() } }
    }

    /// Latest pack preparation failure. A failed pack publishes flat fallback
    /// meshes and resolves readiness instead of pinning the previous generation.
    public var preparationError: String? { state.withLock { $0.preparationError } }

    /// True until the latest CPU pack has either uploaded or selected fallback.
    /// The session uses this to keep interrupted-load recovery active through GPU preparation.
    public var packPreparationPending: Bool { state.withLock { !$0.packReady } }

    // Diagnostic seam: a device-less scene retains only the source awaiting upload.
    var retainsPackSource: Bool { state.withLock { $0.packSource != nil } }

    public func setMipmaps(_ enabled: Bool) {
        state.withLock { $0.mipmaps = enabled }
    }

    func mipmapsIfAvailable() -> Bool? { state.withLockIfAvailable { $0.mipmaps } }

    private func beginGeneration(_ generation: UInt64, replacingPack: Bool, pack: BakedResourcePack?) {
        let schedule = state.withLock { state in
            guard generation > state.generation else { return false }
            state.generation = generation
            state.cpu = [:]; state.pending = [:]; state.gpu = [:]; state.failed = [:]
            state.staging = !state.visibleGPU.isEmpty
            if replacingPack {
                state.packRevision &+= 1
                state.packSource = pack; state.pack = nil; state.packReady = pack == nil
                state.preparationError = nil
            }
            if !state.staging && state.packReady {
                state.visibleGeneration = generation; state.visiblePack = state.pack
                for consumer in state.consumers { consumer.value?.reset(generation: generation, pack: state.pack) }
            }
            state.completionRequested = false
            guard !state.packReady, state.device != nil, !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { worker.async { self.preparePending() } }
    }

    /// Meshing is complete. Publication waits for every latest revision to be prepared.
    public func completeGeneration(_ generation: UInt64) {
        state.withLock { state in
            guard generation == state.generation, state.staging else { return }
            state.completionRequested = true
            Self.commitIfReady(&state)
        }
    }

    /// A live update received during staging adds another meshing round.
    @discardableResult public func invalidateCompletion(_ generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation, state.staging else { return false }
            state.completionRequested = false
            return true
        }
    }

    private static func commitIfReady(_ state: inout State) {
        guard state.staging, state.completionRequested else { return }
        guard state.device != nil, state.packReady else { return }
        guard state.pending.isEmpty, state.cpu.allSatisfy({
            state.gpu[$0.key]?.revision == $0.value.revision || state.failed[$0.key] == $0.value.revision
        }) else { return }
        state.visibleGeneration = state.generation
        state.visibleGPU = state.gpu
        state.visiblePack = state.pack
        state.staging = false
        state.consumers.removeAll { $0.value == nil }
        for consumer in state.consumers {
            consumer.value?.reset(generation: state.generation, batches: state.gpu, pack: state.pack)
        }
    }

    /// Synchronous enqueue only. An empty batch removes the previous mesh for this key.
    /// A newer generation implicitly resets the scene; stale generations cannot repopulate it.
    public func publish(_ upload: BatchUpload) {
        let schedule = state.withLock { state in
            guard upload.generation >= state.generation else { return false }
            if upload.generation > state.generation {
                state.generation = upload.generation
                state.visibleGeneration = upload.generation
                state.visibleGPU = [:]
                state.staging = false; state.completionRequested = false
                state.cpu.removeAll()
                state.pending.removeAll()
                state.gpu.removeAll()
                state.failed.removeAll()
                for consumer in state.consumers { consumer.value?.reset(generation: upload.generation, pack: state.pack) }
            }
            state.revision &+= 1
            let entry = Entry(revision: state.revision, upload: upload)
            state.cpu[upload.key] = entry
            state.pending[upload.key] = entry
            guard state.device != nil, !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { worker.async { self.preparePending() } }
    }

    public func snapshot() -> Snapshot {
        state.withLock { Snapshot(generation: $0.generation, batches: $0.cpu.mapValues(\.upload)) }
    }

    /// Allocation/validation failures omit a staged key or retain its last live mesh. CPU state
    /// remains available for diagnostics and a later device attachment or publication.
    public var preparationFailureCount: Int { state.withLock { $0.failures } }

    func attach(device: any MTLDevice) throws -> BatchMailbox {
        let mailbox = BatchMailbox()
        let schedule = try state.withLock { state in
            // A scene can be reopened on the same Metal device. Mixing devices in
            // one scene would send buffers to incompatible command encoders.
            if let previous = state.device, previous.registryID != device.registryID {
                throw BatchPreparationError.differentDevice
            }
            state.device = device
            mailbox.reset(generation: state.visibleGeneration, batches: state.visibleGPU, pack: state.visiblePack)
            state.consumers.removeAll { $0.value == nil }
            state.consumers.append(WeakMailbox(value: mailbox))
            for (key, entry) in state.cpu where state.gpu[key]?.revision != entry.revision && state.failed[key] != entry.revision {
                state.pending[key] = entry
            }
            Self.commitIfReady(&state)
            guard (!state.pending.isEmpty || !state.packReady), !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { worker.async { self.preparePending() } }
        return mailbox
    }

    private func preparePending() {
        while true {
            // Always resolve the latest pack before dequeuing more geometry.
            // updatePack closes the publication gate synchronously, even when an
            // earlier geometry/pack request is already running on this worker.
            let packRequest = state.withLock { state -> (BakedResourcePack, UInt64, any MTLDevice, PreparedPack?)? in
                guard !state.packReady, let source = state.packSource, let device = state.device else { return nil }
                return (source, state.packRevision, device, state.pack)
            }
            if let (source, revision, device, previous) = packRequest {
                let result = Result { try PreparedPack.prepare(source, device: device, extending: previous) }
                state.withLock { state in
                    guard state.packRevision == revision else { return }
                    state.packSource = nil
                    state.packReady = true
                    switch result {
                    case .success(let pack):
                        state.pack = pack
                        state.preparationError = nil
                    case .failure(let error):
                        state.pack = nil
                        state.preparationError = String(describing: error)
                        state.failures += 1
                        log.error("PACK preparation failed: \(String(describing: error), privacy: .public)")
                    }
                    if state.staging {
                        Self.commitIfReady(&state)
                    } else {
                        state.visibleGeneration = state.generation
                        state.visiblePack = state.pack
                        state.visibleGPU = state.gpu
                        for c in state.consumers {
                            c.value?.reset(generation: state.generation, batches: state.gpu, pack: state.pack)
                        }
                    }
                }
                continue
            }
            let next: (Entry, any MTLDevice)? = state.withLock { state in
                // A pack request can arrive between the two lock acquisitions.
                guard state.packReady else { return nil }
                if let device = state.device {
                    while let (key, entry) = state.pending.first {
                        state.pending.removeValue(forKey: key)
                        if state.gpu[key]?.revision != entry.revision && state.failed[key] != entry.revision {
                            return (entry, device)
                        }
                    }
                }
                Self.commitIfReady(&state)
                state.scheduled = false
                return nil
            }
            // If updatePack raced the dequeue, keep this scheduled worker alive.
            if next == nil, state.withLock({ !$0.packReady && $0.packSource != nil && $0.device != nil }) { continue }
            guard let (entry, device) = next else { return }
            autoreleasepool {
                let result = Result { try PreparedBatch.prepare(entry.upload, revision: entry.revision, device: device) }
                state.withLock { state in
                    guard state.generation == entry.upload.generation,
                          state.cpu[entry.upload.key]?.revision == entry.revision else { return }
                    switch result {
                    case .success(let prepared):
                        state.gpu[entry.upload.key] = prepared
                        state.failed.removeValue(forKey: entry.upload.key)
                        state.consumers.removeAll { $0.value == nil }
                        if state.staging {
                            Self.commitIfReady(&state)
                        } else if state.packReady {
                            state.visibleGPU[entry.upload.key] = prepared
                            for consumer in state.consumers { consumer.value?.publish(prepared) }
                        }
                    case .failure(let error):
                        state.failures += 1
                        state.failed[entry.upload.key] = entry.revision
                        if state.staging { state.gpu.removeValue(forKey: entry.upload.key) }
                        // Resolve this revision without pinning a replacement forever.
                        // A later publication has a new revision and retries preparation.
                        log.error("BATCH preparation failed generation=\(entry.upload.generation) key=\(String(describing: entry.upload.key), privacy: .public) revision=\(entry.revision): \(String(describing: error), privacy: .public)")
                        Self.commitIfReady(&state)
                    }
                }
            }
        }
    }

    /// Release replaced meshes away from the render thread, including reset dictionaries.
    func retire(_ batches: [SIMD3<Int>: PreparedBatch]) {
        worker.async { withExtendedLifetime(batches) {} }
    }

    func retire(_ drawing: PreparedDrawScene) {
        worker.async { withExtendedLifetime(drawing) {} }
    }

    func retire(_ batches: [PreparedBatch]) {
        worker.async { withExtendedLifetime(batches) {} }
    }
}

public enum BatchPreparationError: Error {
    case differentDevice, invalidGeometry, resourceAllocation
}

// Metal's MTLBuffer protocol is not Sendable in this SDK. These buffers are
// initialized entirely on the preparation worker, then published under a mutex.
// No code ever mutates their contents after publication; renderers only bind/read
// them, and Metal command buffers retain resources for in-flight draws.
struct PreparedBatch: @unchecked Sendable {
    let generation: UInt64
    let revision: UInt64
    let key: SIMD3<Int>
    let vertices: (any MTLBuffer)?
    let indices: (any MTLBuffer)?
    let indexCount: Int
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    let packed: Bool
    let ranges: BatchRanges
    let transform: SIMD4<Float> // translation in table metres, block size in w
    let cellOrigin: SIMD4<Int32>

    static func prepare(_ upload: BatchUpload, revision: UInt64, device: any MTLDevice) throws -> Self {
        let data = upload.data
        let ranges = try BatchRanges(data)
        guard upload.blockSize.isFinite, upload.blockSize > 0,
              upload.position.allFinite, upload.center.allFinite,
              data.min.allFinite, data.max.allFinite,
              data.verts.count <= Int(UInt32.max),
              data.indices.allSatisfy({ $0 >= 0 && $0 < data.verts.count }),
              upload.cellOrigin.x >= Int(Int32.min), upload.cellOrigin.x <= Int(Int32.max),
              upload.cellOrigin.y >= Int(Int32.min), upload.cellOrigin.y <= Int(Int32.max),
              upload.cellOrigin.z >= Int(Int32.min), upload.cellOrigin.z <= Int(Int32.max),
              data.verts.allSatisfy({ $0.pos.allFinite && $0.uv.allFinite }) else { throw BatchPreparationError.invalidGeometry }
        let translation = (upload.position - upload.center) * upload.blockSize
        let a = data.min * upload.blockSize + translation, b = data.max * upload.blockSize + translation
        let packedBytes = data.packedBytes()
        let bytes = packedBytes ?? BatchEncoding.classicBytes(data.verts)
        var vb: (any MTLBuffer)?, ib: (any MTLBuffer)?
        if !data.indices.isEmpty {
            let indices = data.indices.map { UInt32($0) }
            vb = bytes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            ib = indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard vb != nil, ib != nil else { throw BatchPreparationError.resourceAllocation }
        }
        return Self(generation: upload.generation, revision: revision, key: upload.key,
                    vertices: vb, indices: ib, indexCount: data.indices.count, boundsMin: a, boundsMax: b,
                    packed: packedBytes != nil, ranges: ranges, transform: SIMD4(translation, upload.blockSize),
                    cellOrigin: SIMD4(Int32(upload.cellOrigin.x), Int32(upload.cellOrigin.y), Int32(upload.cellOrigin.z), 0))
    }

}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

final class BatchMailbox: Sendable {
    enum Update: Sendable {
        case replace(UInt64, [SIMD3<Int>: PreparedBatch])
        case batch(PreparedBatch)
    }
    private struct State: Sendable {
        var generation: UInt64 = 0
        var batches: [SIMD3<Int>: PreparedBatch] = [:]
        var retained: [SIMD3<Int>: PreparedBatch] = [:]
        var pack: PreparedPack?
        var render: PreparedDrawScene?
    }
    private let state = Mutex(State())

    func reset(generation: UInt64, batches: [SIMD3<Int>: PreparedBatch] = [:], pack: PreparedPack? = nil) {
        // Give this mailbox unique dictionary storage. A COW snapshot of the GPU
        // cache would otherwise copy all entries on the first render-thread pop.
        state.withLock { $0 = State(generation: generation, batches: batches.mapValues { $0 }, retained: batches, pack: pack, render: PreparedDrawScene(generation: generation, batches: batches, pack: pack)) }
    }
    func publish(_ batch: PreparedBatch) {
        state.withLock { state in
            guard batch.generation == state.generation else { return }
            state.batches[batch.key] = batch
            state.retained[batch.key] = batch
            state.render = PreparedDrawScene(generation: state.generation, batches: state.retained, pack: state.pack)
        }
    }
    func takeRenderScene() -> PreparedDrawScene? {
        state.withLockIfAvailable { state in
            let next = state.render; state.render = nil; return next
        } ?? nil
    }

    func next(generation: UInt64?) -> Update? {
        // Never wait behind a producer on the real-time render path.
        state.withLockIfAvailable { state -> Update? in
            if generation != state.generation {
                let batches = state.batches
                state.batches = [:]
                return .replace(state.generation, batches)
            }
            guard let (key, batch) = state.batches.first else { return nil }
            state.batches.removeValue(forKey: key)
            return .batch(batch)
        } ?? nil
    }
}
#endif
