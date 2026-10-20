#if canImport(Metal)
import Foundation
import TabletopCore

/// Mutable pack readers and CPU baking never run on the session actor. Cancellation
/// is checked between complete atlas cache resolutions; interrupted work can be
/// resumed on the same atlas without publishing an incomplete bake.
actor PackBakeWorker {
    struct Bake: Sendable {
        let revision: UInt64
        let pack: BakedResourcePack
    }
    private var latest: Bake?
    private var revision: UInt64 = 0
    private var atlas: ResourcePackAtlas?
    private var prepared: Set<String> = []

    func load(_ url: URL, states: [String]) throws -> Bake {
        try Task.checkCancellation()
        let next = try ResourcePackAtlas(path: url.path)
        next.prewarm(states)
        let value = try next.checkedBaked()
        guard !value.layers.isEmpty else { throw JsonError("pack contains no usable textures") }
        try Task.checkCancellation()
        atlas = next; prepared = Set(states)
        revision &+= 1
        let result = Bake(revision: revision, pack: value)
        latest = result
        return result
    }

    func prewarm(_ states: [String]) throws -> Bake? {
        guard let atlas else { return nil }
        let added = states.filter { !prepared.contains($0) }
        guard !added.isEmpty else { return latest }
        try Task.checkCancellation()
        atlas.prewarm(added)
        let value = try atlas.checkedBaked()
        try Task.checkCancellation()
        prepared.formUnion(added)
        revision &+= 1
        let result = Bake(revision: revision, pack: value)
        latest = result
        return result
    }
}

/// Written *before* loading the installed file. A process killed during baking
/// leaves this marker behind, preventing the next launch from repeating the load.
struct PackLoadQuarantine {
    let directory: URL
    var marker: URL { directory.appendingPathComponent("pack-load-failure.txt") }
    var reason: String? { try? String(contentsOf: marker, encoding: .utf8) }
    func mark(_ reason: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try reason.write(to: marker, atomically: true, encoding: .utf8)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }
}
#endif
