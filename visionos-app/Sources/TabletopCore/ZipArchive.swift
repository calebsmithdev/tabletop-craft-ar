// CPU ZIP reader for ResourcePackAtlas.cs / Tests~/PackAssets.cs at f7d4a0f4536791c0d46ea296d45c1794ffd755e4.
// Foundation + the Apple SDK's zlib; central-directory indexed, entries read on demand from disk.
import Foundation
import zlib

public struct ZipArchiveError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Serial-owner reader. No extraction, temporary files, UI frameworks or shared mutable globals.
/// ZIP64, multi-disk and encrypted archives are deliberately unsupported.
public final class ZipArchive {
    private struct Entry {
        let method, flags, compressedSize, size, offset: Int
        let crc: UInt32
    }
    private let file: FileHandle
    private var entries: [String: Entry] = [:]
    public private(set) var names: [String] = []
    public static let maxEntryBytes = 256 * 1024 * 1024

    public init(path: String) throws {
        file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        do { try index() }
        catch { try? file.close(); throw error }
    }
    deinit { try? file.close() }

    private func bytes(_ offset: Int, _ count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0 else { throw ZipArchiveError("Invalid ZIP range") }
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ZipArchiveError("Truncated ZIP") }
        return Array(data)
    }
    private func index() throws {
        let fileSize64 = try file.seekToEnd()
        guard let fileSize = Int(exactly: fileSize64), fileSize >= 22 else { throw ZipArchiveError("Missing ZIP directory") }
        let tailCount = min(fileSize,65535+22), start = fileSize-tailCount
        let tail = try bytes(start,tailCount)
        var end: Int?
        for i in stride(from: tail.count-22,through: 0,by: -1) {
            if le32(tail,i) == 0x06054b50 && i+22+le16(tail,i+20) == tail.count { end = i; break }
        }
        guard let e = end else { throw ZipArchiveError("Missing ZIP directory") }
        let count = le16(tail,e+10), directorySize = le32(tail,e+12), directoryOffset = le32(tail,e+16)
        guard le16(tail,e+4) == 0, le16(tail,e+6) == 0, le16(tail,e+8) == count,
              count != 0xffff, directorySize != 0xffffffff, directoryOffset != 0xffffffff,
              directoryOffset+directorySize <= start+e else { throw ZipArchiveError("Unsupported ZIP64 or multi-disk archive") }
        var pos = directoryOffset
        for _ in 0..<count {
            let h = try bytes(pos,46)
            guard le32(h,0) == 0x02014b50 else { throw ZipArchiveError("Invalid ZIP directory record") }
            let nameLength = le16(h,28), extraLength = le16(h,30), commentLength = le16(h,32)
            let next = pos+46+nameLength+extraLength+commentLength
            guard next <= directoryOffset+directorySize, le16(h,34) == 0 else { throw ZipArchiveError("Invalid ZIP directory bounds") }
            let rawName = try bytes(pos+46,nameLength)
            guard let name = String(bytes: rawName,encoding: .utf8) else { throw ZipArchiveError("ZIP filename is not UTF-8") }
            let entry = Entry(method: le16(h,10),flags: le16(h,8),compressedSize: le32(h,20),
                              size: le32(h,24),offset: le32(h,42),crc: UInt32(le32(h,16)))
            guard entry.size != 0xffffffff, entry.compressedSize != 0xffffffff, entry.offset != 0xffffffff,
                  entry.offset+30+entry.compressedSize <= directoryOffset else { throw ZipArchiveError("Invalid ZIP entry bounds") }
            // ZipArchive.GetEntry returns the first duplicate.
            if entries[name] == nil { entries[name] = entry; names.append(name) }
            pos = next
        }
    }
    public func read(_ path: String) throws -> [UInt8]? {
        guard let e = entries[path] else { return nil }
        guard e.flags & 1 == 0, e.method == 0 || e.method == 8 else { throw ZipArchiveError("Encrypted or unsupported ZIP entry: \(path)") }
        guard e.size <= Self.maxEntryBytes, e.compressedSize <= Self.maxEntryBytes else { throw ZipArchiveError("ZIP entry too large: \(path)") }
        let h = try bytes(e.offset,30)
        guard le32(h,0) == 0x04034b50, le16(h,8) == e.method, le16(h,6) == e.flags else { throw ZipArchiveError("Invalid ZIP local record") }
        let input = try bytes(e.offset+30+le16(h,26)+le16(h,28),e.compressedSize)
        let output: [UInt8]
        if e.method == 0 {
            guard input.count == e.size else { throw ZipArchiveError("Incorrect stored ZIP entry size") }
            output = input
        } else { output = try inflateBytes(input, size: e.size, raw: true) }
        let crc = output.withUnsafeBufferPointer { crc32(0,$0.baseAddress,uInt($0.count)) }
        guard UInt32(crc) == e.crc else { throw ZipArchiveError("ZIP CRC mismatch: \(path)") }
        return output
    }
}

private func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 }
private func le32(_ b: [UInt8], _ i: Int) -> Int { le16(b,i) | le16(b,i+2) << 16 }

func inflateBytes(_ input: [UInt8], size: Int, raw: Bool) throws -> [UInt8] {
    guard size >= 0, size <= ZipArchive.maxEntryBytes, input.count <= Int(UInt32.max) else { throw ZipArchiveError("Inflated data too large") }
    // One spare byte permits empty streams and detects output longer than the advertised size.
    var output = [UInt8](repeating: 0,count: size+1), stream = z_stream()
    let initialized = inflateInit2_(&stream,raw ? -MAX_WBITS : MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))
    guard initialized == Z_OK else { throw ZipArchiveError("Cannot initialize zlib") }
    defer { inflateEnd(&stream) }
    let status = input.withUnsafeBufferPointer { src in
        output.withUnsafeMutableBufferPointer { dst in
            stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
            stream.avail_in = uInt(src.count)
            stream.next_out = dst.baseAddress
            stream.avail_out = uInt(dst.count)
            return inflate(&stream,Z_FINISH)
        }
    }
    guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else { throw ZipArchiveError("Invalid or truncated deflate stream") }
    output.removeLast()
    return output
}
