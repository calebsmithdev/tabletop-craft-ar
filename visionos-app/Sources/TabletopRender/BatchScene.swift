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

    public init(generation: UInt64, key: SIMD3<Int>, data: BatchData,
                position: SIMD3<Float>, blockSize: Float, center: SIMD3<Float>) {
        self.generation = generation
        self.key = key
        self.data = data
        self.position = position
        self.blockSize = blockSize
        self.center = center
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
            state.staging = false
            state.completionRequested = false
            state.cpu.removeAll()
            state.pending.removeAll()
            state.gpu.removeAll()
            state.failed.removeAll()
            state.consumers.removeAll { $0.value == nil }
            for consumer in state.consumers { consumer.value?.reset(generation: generation) }
        }
    }

    /// Stage replacements while visible content remains drawn; empty scenes load progressively.
    public func beginGeneration(_ generation: UInt64) {
        state.withLock { state in
            guard generation > state.generation else { return }
            state.generation = generation
            state.cpu = [:]; state.pending = [:]; state.gpu = [:]; state.failed = [:]
            state.staging = !state.visibleGPU.isEmpty
            if !state.staging {
                state.visibleGeneration = generation
                for consumer in state.consumers { consumer.value?.reset(generation: generation) }
            }
            state.completionRequested = false
        }
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
        guard state.device != nil else { return }
        guard state.pending.isEmpty, state.cpu.allSatisfy({
            state.gpu[$0.key]?.revision == $0.value.revision || state.failed[$0.key] == $0.value.revision
        }) else { return }
        state.visibleGeneration = state.generation
        state.visibleGPU = state.gpu
        state.staging = false
        state.consumers.removeAll { $0.value == nil }
        for consumer in state.consumers {
            consumer.value?.reset(generation: state.generation, batches: state.gpu)
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
                for consumer in state.consumers { consumer.value?.reset(generation: upload.generation) }
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
            mailbox.reset(generation: state.visibleGeneration, batches: state.visibleGPU)
            state.consumers.removeAll { $0.value == nil }
            state.consumers.append(WeakMailbox(value: mailbox))
            for (key, entry) in state.cpu where state.gpu[key]?.revision != entry.revision && state.failed[key] != entry.revision {
                state.pending[key] = entry
            }
            Self.commitIfReady(&state)
            guard !state.pending.isEmpty, !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { worker.async { self.preparePending() } }
        return mailbox
    }

    private func preparePending() {
        while true {
            let next: (Entry, any MTLDevice)? = state.withLock { state in
                if let device = state.device {
                    while let (key, entry) = state.pending.first {
                        state.pending.removeValue(forKey: key)
                        // Attachment can requeue an in-flight revision. Resolve it once.
                        if state.gpu[key]?.revision != entry.revision && state.failed[key] != entry.revision {
                            return (entry, device)
                        }
                    }
                }
                // Skipping an attachment's duplicate may remove the last readiness blocker.
                Self.commitIfReady(&state)
                state.scheduled = false
                return nil
            }
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
                        } else {
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

    // Two float4s, 32-byte stride; this deliberately does not upload BatchVertex's ABI.
    private struct Vertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
    }

    static func prepare(_ upload: BatchUpload, revision: UInt64, device: any MTLDevice) throws -> Self {
        let data = upload.data
        guard upload.blockSize.isFinite, upload.blockSize > 0,
              upload.position.allFinite, upload.center.allFinite,
              data.min.allFinite, data.max.allFinite,
              data.indices.count.isMultiple(of: 3), data.waterBack >= 0,
              data.waterBack <= data.indices.count else { throw BatchPreparationError.invalidGeometry }
        let count = data.indices.count - data.waterBack
        guard count.isMultiple(of: 3) else { throw BatchPreparationError.invalidGeometry }
        let a = (data.min + upload.position - upload.center) * upload.blockSize
        let b = (data.max + upload.position - upload.center) * upload.blockSize
        if data.verts.isEmpty || count == 0 {
            return Self(generation: upload.generation, revision: revision, key: upload.key,
                        vertices: nil, indices: nil, indexCount: 0, boundsMin: a, boundsMax: b)
        }
        guard data.verts.count <= Int(UInt32.max),
              data.indices.allSatisfy({ $0 >= 0 && $0 < data.verts.count }) else {
            throw BatchPreparationError.invalidGeometry
        }
        // Double-sided specials can have cancelling accumulated normals. Recover
        // their first geometric normal for shading without changing any indices.
        var normals = data.verts.map { SIMD3<Float>(Float($0.nx), Float($0.ny), Float($0.nz)) }
        for i in stride(from: 0, to: count, by: 3) {
            let ia = data.indices[i], ib = data.indices[i + 1], ic = data.indices[i + 2]
            let n = simd_cross(data.verts[ib].pos - data.verts[ia].pos,
                               data.verts[ic].pos - data.verts[ia].pos)
            for index in [ia, ib, ic] where normals[index] == .zero { normals[index] = n }
        }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(data.verts.count)
        for (i, vertex) in data.verts.enumerated() {
            let position = (vertex.pos + upload.position - upload.center) * upload.blockSize
            guard position.allFinite else { throw BatchPreparationError.invalidGeometry }
            let n = normals[i], absolute = simd_abs(n)
            let shade: Float
            if absolute.y >= absolute.x && absolute.y >= absolute.z { shade = n.y >= 0 ? 1 : 0.5 }
            else if absolute.z >= absolute.x { shade = 0.8 }
            else { shade = 0.6 }
            let color = vertex.color
            // M1b is the flat opaque-colour milestone; no texture/alpha material passes yet.
            vertices.append(Vertex(position: SIMD4(position, 1), color: SIMD4(
                Float(color.r) / 255 * shade, Float(color.g) / 255 * shade, Float(color.b) / 255 * shade, 1)))
        }
        let indices = data.indices.prefix(count).map { UInt32($0) }
        guard let vb = vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let ib = indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw BatchPreparationError.resourceAllocation
        }
        vb.label = "Tabletop batch vertices"
        ib.label = "Tabletop batch indices"
        return Self(generation: upload.generation, revision: revision, key: upload.key,
                    vertices: vb, indices: ib, indexCount: count, boundsMin: a, boundsMax: b)
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
    }
    private let state = Mutex(State())

    func reset(generation: UInt64, batches: [SIMD3<Int>: PreparedBatch] = [:]) {
        // Give this mailbox unique dictionary storage. A COW snapshot of the GPU
        // cache would otherwise copy all entries on the first render-thread pop.
        state.withLock { $0 = State(generation: generation, batches: batches.mapValues { $0 }) }
    }
    func publish(_ batch: PreparedBatch) {
        state.withLock { state in
            guard batch.generation == state.generation else { return }
            state.batches[batch.key] = batch
        }
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
