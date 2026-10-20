import Foundation
import CryptoKit
import Testing
@testable import TabletopCore

struct AssetSyncTests {
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func offer(_ files: [(String, Data)], chunk: Int = 1024, badHash: Bool = false) -> JSONObject {
        ["type": "assets", "chunk": .number(Double(chunk)), "files": .array(files.map { name, data in
            .object(["name": .string(name), "size": .number(Double(data.count)),
                     "sha256": .string(badHash ? String(repeating: "0", count: 64) : digest(data))])
        })]
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("asset-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
    private func answer(_ request: JSONObject, bytes: Data) throws -> Data {
        let offset = request.i("offset"), length = request.i("length")
        let name = try #require(request.s("name"))
        return try #require(AssetProtocol.frame(name: name, offset: Int64(offset),
                                               data: bytes.subdata(in: offset..<(offset + length))))
    }
    private func finish(_ sync: AssetSync, bytes: Data) async throws {
        for _ in 0..<100 {
            let requests = await sync.drainRequests()
            for request in requests { await sync.receiveBinary(try answer(request, bytes: bytes)) }
            if !(await sync.snapshot()).busy { return }
        }
        Issue.record("download did not settle")
    }

    @Test func assetProtocolRejectsUnsafeOffersAndMalformedFrames() throws {
        let bytes = Data("abc".utf8)
        var message = offer([("pack.zip", bytes), ("../pack.zip", bytes), ("pack.zip", bytes)])
        message["chunk"] = .number(Double(Int.max))
        let parsed = AssetProtocol.parseOffer(message)
        #expect(parsed.files.count == 1)
        #expect(parsed.chunk == AssetProtocol.maxChunk)
        #expect(AssetProtocol.parseOffer(["chunk": 0]).chunk == 1024)
        #expect(AssetProtocol.parseOffer(["files": [["name": "pack.zip", "size": 1, "sha256": .string(String(repeating: "z", count: 64))]]]).files.isEmpty)
        let frame = try #require(AssetProtocol.frame(name: "sounds.zip", offset: 262144, data: bytes))
        let chunk = try #require(AssetProtocol.parseChunk(frame))
        #expect(chunk.name == "sounds.zip" && chunk.offset == 262144 && chunk.data == bytes)
        #expect(AssetProtocol.parseChunk(frame.dropLast(3)) == nil)
        var negative = frame; negative[15] = 255 // first offset byte after 10-byte sounds.zip
        #expect(AssetProtocol.parseChunk(negative) == nil)
        #expect(AssetProtocol.parseChunk(Data("bad".utf8)) == nil)
        var prefixed = Data([0]); prefixed.append(frame)
        #expect(AssetProtocol.parseChunk(prefixed.dropFirst()) == chunk)
    }

    @Test func assetDownloadsAtMostFourAndCachesVerifiedFiles() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<10500).map { UInt8($0 % 251) })
        let sync = AssetSync(directory: dir)
        await sync.acceptOffer(offer([("pack.zip", bytes)]))
        let requests = await sync.drainRequests()
        #expect(requests.count == 4)
        #expect((await sync.drainRequests()).isEmpty)
        // Unrequested, out-of-order and short frames leave the window intact.
        await sync.receiveBinary(try answer(requests[1], bytes: bytes))
        await sync.receiveBinary(try #require(AssetProtocol.frame(name: "pack.zip", offset: 0, data: Data([0]))))
        #expect((await sync.snapshot()).items[0].inFlight == 4)
        for request in requests { await sync.receiveBinary(try answer(request, bytes: bytes)) }
        try await finish(sync, bytes: bytes)
        let snapshot = await sync.snapshot()
        #expect(snapshot.items[0].state == .done && snapshot.downloaded == 1)
        #expect(snapshot.bytesReceived == Int64(bytes.count))
        let completed = await sync.drainCompletions()
        #expect(completed.count == 1 && completed[0].name == "pack.zip")
        #expect(try Data(contentsOf: #require(completed.first).url) == bytes)
        #expect((await sync.drainCompletions()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pack.zip.part").path))
        let cached = AssetSync(directory: dir, hash: { _ in throw CocoaError(.fileReadUnknown) })
        await cached.acceptOffer(offer([("pack.zip", bytes)]))
        #expect((await cached.snapshot()).items[0].state == .upToDate)
        #expect((await cached.drainRequests()).isEmpty)
        // Changing the timestamp invalidates the cache, forcing the injected failing hash.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)],
                                             ofItemAtPath: dir.appendingPathComponent("pack.zip").path)
        let changed = AssetSync(directory: dir, hash: { _ in throw CocoaError(.fileReadUnknown) })
        await changed.acceptOffer(offer([("pack.zip", bytes)]))
        #expect((await changed.snapshot()).items[0].state == .waiting)
    }

    @Test func explicitRetryRedownloadsEvenAHashMatchingInstalledPack() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 42, count: 3000)
        try bytes.write(to: dir.appendingPathComponent("pack.zip"))
        let sync = AssetSync(directory: dir)
        let message = offer([("pack.zip", bytes)])
        await sync.acceptOffer(message)
        #expect(await sync.snapshot().items[0].state == .upToDate)
        await sync.forceDownload("pack.zip")
        await sync.linkLost()
        await sync.acceptOffer(message)
        #expect(await sync.snapshot().items[0].state == .waiting)
        try await finish(sync, bytes: bytes)
        #expect(await sync.drainCompletions().count == 1)
        await sync.acceptOffer(message)
        #expect(await sync.snapshot().items[0].state == .upToDate)
    }

    @Test func repeatedOfferRechecksAFileReplacedByManualImport() async throws {
        for initiallyDownloaded in [false, true] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let bytes = Data(repeating: 4, count: 3000), imported = Data(repeating: 7, count: 3000)
            let destination = dir.appendingPathComponent("pack.zip"), message = offer([("pack.zip", bytes)])
            if !initiallyDownloaded { try bytes.write(to: destination) }
            let sync = AssetSync(directory: dir)
            await sync.acceptOffer(message)
            if initiallyDownloaded { try await finish(sync, bytes: bytes) }
            #expect([AssetSync.State.done, .upToDate].contains((await sync.snapshot()).items[0].state))
            try imported.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: destination.path)
            await sync.acceptOffer(message)
            #expect((await sync.snapshot()).items[0].state == .waiting)
            try await finish(sync, bytes: bytes)
            #expect(try Data(contentsOf: destination) == bytes)
            await sync.acceptOffer(message)
            #expect((await sync.snapshot()).items[0].state == .upToDate)
            #expect((await sync.drainRequests()).isEmpty)
        }
    }

    @Test func assetResumesAcrossInstancesAndWaitsForOfferAfterLinkLoss() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 42, count: 7500)
        let sync = AssetSync(directory: dir)
        let message = offer([("sounds.zip", bytes)])
        await sync.acceptOffer(message)
        let requests = await sync.drainRequests()
        for request in requests.prefix(3) { await sync.receiveBinary(try answer(request, bytes: bytes)) }
        await sync.linkLost()
        #expect((await sync.drainRequests()).isEmpty)
        await sync.receiveBinary(try answer(requests[3], bytes: bytes))
        let resumed = AssetSync(directory: dir)
        await resumed.acceptOffer(message)
        let next = await resumed.drainRequests()
        #expect(next.first?.i("offset") == 3072)
        for request in next { await resumed.receiveBinary(try answer(request, bytes: bytes)) }
        try await finish(resumed, bytes: bytes)
        #expect(try Data(contentsOf: dir.appendingPathComponent("sounds.zip")) == bytes)
    }

    @Test func assetChecksumFailurePreservesDestinationAndChangedOfferDiscardsPart() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = Data([1, 2, 3]), bytes = Data(repeating: 9, count: 5000)
        try old.write(to: dir.appendingPathComponent("pack.zip"))
        let sync = AssetSync(directory: dir)
        await sync.acceptOffer(offer([("pack.zip", bytes)], badHash: true))
        try await finish(sync, bytes: bytes)
        #expect((await sync.snapshot()).items[0].state == .failed)
        #expect((await sync.drainCompletions()).isEmpty)
        #expect(try Data(contentsOf: dir.appendingPathComponent("pack.zip")) == old)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pack.zip.part").path))
        await sync.acceptOffer(offer([("pack.zip", bytes)]))
        let requests = await sync.drainRequests()
        await sync.receiveBinary(try answer(requests[0], bytes: bytes))
        let different = Data(repeating: 8, count: 5000)
        await sync.acceptOffer(offer([("pack.zip", different)]))
        #expect((await sync.drainRequests()).first?.i("offset") == 0)
        await sync.linkLost()
    }

    @Test func assetFilteringErrorsStallsAndServerStatus() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 1, count: 6000)
        let sync = AssetSync(directory: dir, allowedNames: ["pack.zip", "evil.sh"])
        await sync.acceptOffer(offer([("sounds.zip", bytes), ("pack.zip", bytes), ("evil.sh", bytes)]))
        #expect((await sync.snapshot()).items.count == 1)
        let initial = await sync.drainRequests(now: 100)
        #expect(initial.count == 4)
        #expect((await sync.drainRequests(now: 116)) == initial)
        await sync.receiveBinary(try answer(initial[0], bytes: bytes), now: 116)
        #expect(await sync.receiveError(["op": "asset_get", "name": "pack.zip", "code": "rate_limited"]))
        #expect((await sync.drainRequests(now: 117)).first?.i("offset") == 1024)
        #expect(!(await sync.receiveError(["op": "block_edit"])))
        #expect(await sync.receiveError(["op": "asset_get", "code": "asset_denied"]))
        #expect((await sync.snapshot()).items[0].state == .failed)
        await sync.acceptOffer(["state": "building", "note": "preparing", "files": []])
        #expect((await sync.snapshot()).status.contains("preparing"))
    }

    @Test func assetSymlinkDestinationsAreRejected() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("outside"), bytes = Data(repeating: 3, count: 20)
        try Data([7]).write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("pack.zip.part"), withDestinationURL: target)
        let sync = AssetSync(directory: dir)
        await sync.acceptOffer(offer([("pack.zip", bytes)]))
        #expect((await sync.drainRequests()).isEmpty)
        #expect((await sync.snapshot()).items[0].state == .failed)
        #expect(try Data(contentsOf: target) == Data([7]))
    }
}
