// Port of quest-app/Assets/Scripts/World/SnapshotAssembler.cs at 4d321b4.
import Foundation

// Synchronous, value-owned decoder for CLI and actor owners. offer completes decoding;
// busy means a completed result is waiting to be consumed. No unstructured worker task.
public struct SnapshotAssembler: Sendable {
    public struct Result: Sendable {
        public var snapshotId: Int
        public var snapshot: ChunkSnapshot?
        public var plan: SectionPlan?
        public var viewMargin = SIMD3<Int>.zero
        public var error: String?
        public var delta = false
        public var parts = 1
        public var listed = -1
        public var listedKeys: Set<SIMD3<Int>>?
        public var ms = 0.0
    }
    private var parts: [JSONObject] = []
    private var partsId: Int?
    private var partsTotal = 0
    private var result: Result?
    /// Latest server-advertised limits.max_blocks; nil uses the client hard cap.
    public var maxBlocks: Int?
    /// Enable only for consumers that reuse section meshes; full remesh consumers skip this work.
    public var computeSectionPlan: Bool
    public init(maxBlocks: Int? = nil, computeSectionPlan: Bool = false) {
        self.maxBlocks = maxBlocks; self.computeSectionPlan = computeSectionPlan
    }
    public var busy: Bool { result != nil }
    public var partsWaiting: Int { parts.count }
    public mutating func offer(_ m: JSONObject, _ current: WorldModel, _ stale: Set<SIMD3<Int>> = []) throws {
        guard !busy else { throw SnapshotError.invalid("snapshot decode already pending; take result first") }
        let start = ContinuousClock.now
        var r = Result(snapshotId: m.i("snapshot_id"))
        do {
            let allocationLimit = SnapshotLimits.allocationLimit(for: maxBlocks)
            let dims = try SnapshotFields.vector(m,"dims")
            _ = try SnapshotFields.volume(dims,maxBlocks: allocationLimit)
            var messages = [m]
            let sectioned = m.s("encoding") == SectionedSnapshot.encoding
            if sectioned {
                let id = try SnapshotFields.integer(m,"snapshot_id"), part = try SnapshotFields.integer(m,"part"), total = try SnapshotFields.integer(m,"parts",1)
                // At most one part per 16³ section. Dimensions are required and
                // validated above, so no unknown-dimensions fallback is needed.
                let sections = SectionPlan.sections(dims)
                let maxParts = sections.x * sections.y * sections.z
                guard total >= 1, total <= maxParts, part >= 0, part < total else { throw SnapshotError.invalid("bad part/parts or exceeds section count") }
                if part == 0 { parts = []; partsId = id; partsTotal = total }
                guard partsId == id, partsTotal == total, part == parts.count else { throw SnapshotError.invalid("parts out of order") }
                parts.append(m)
                if parts.count < total { return }
                messages = parts; parts = []; partsId = nil
            } else { parts = []; partsId = nil }
            if let a = messages[0].a("view_margin"), let v = try? SnapshotFields.ints(a), v.count == 3 { r.viewMargin = SIMD3(max(0,v[0]),max(0,v[1]),max(0,v[2])) }
            var listed: [SIMD3<Int>] = []
            let s = try sectioned ? SectionedSnapshot.assemble(messages,current: current,listed: &listed,maxBlocks: allocationLimit) : ChunkSnapshot.from(m,maxBlocks: allocationLimit)
            r.delta = sectioned && messages[0].o("base") != nil
            r.parts = messages.count; r.listed = sectioned ? listed.count : -1
            if r.delta { r.listedKeys = Set(listed) }
            r.snapshot = s
            if computeSectionPlan { r.plan = SectionPlan.compute(current,s,stale,r.listedKeys) }
        } catch { parts = []; partsId = nil; r.error = String(describing: error) }
        let duration = start.duration(to: .now).components
        r.ms = Double(duration.seconds)*1000 + Double(duration.attoseconds)/1e15
        result = r
    }
    public mutating func tryTake() -> Result? { defer { result = nil }; return result }
    public mutating func wait() -> Result? { tryTake() }
}
