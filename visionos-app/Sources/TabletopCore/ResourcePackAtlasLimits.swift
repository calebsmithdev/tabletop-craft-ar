import Foundation

public enum ResourcePackValidationError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case tileSize(Int)
    case animationFrames(Int)
    case animationSchedule(Int)
    case layerLimit
    case pixelBudget
    case cancelled

    public var description: String {
        switch self {
        case .tileSize(let size): "Resource pack tile size \(size) exceeds the supported 1...\(ResourcePackLimits.maxTileSize) range"
        case .animationFrames(let count): "Resource pack animation has \(count) image frames; limit is \(ResourcePackLimits.maxAnimationFrames)"
        case .animationSchedule(let count): "Resource pack animation schedule has \(count) entries; limit is \(ResourcePackLimits.maxAnimationScheduleEntries)"
        case .layerLimit: "Resource pack exceeds the \(ResourcePackLimits.maxLayers) atlas layer limit"
        case .pixelBudget: "Resource pack exceeds the \(ResourcePackLimits.maxPixelBytes / 1024 / 1024) MiB combined pixel-storage budget"
        case .cancelled: "Resource pack loading was cancelled"
        }
    }
    public var errorDescription: String? { description }
}

/// Conservative per-pack storage accounting, shared by the CPU loader and GPU preparation.
/// Counts independent raw and mip bases even when Swift happens to share their COW storage.
public enum ResourcePackLimits {
    public static let maxTileSize = 256
    public static let maxAnimationFrames = 1024
    public static let maxAnimationScheduleEntries = 1024
    public static let maxLayers = 2048
    public static let maxPixelBytes = 256 * 1024 * 1024

    /// Matches the renderer's growing atlas allocation, including unused slices.
    public static func atlasCapacity(for layers: Int) throws -> Int {
        guard layers >= 0, layers <= maxLayers else { throw ResourcePackValidationError.layerLimit }
        var capacity = 16
        while capacity < layers { capacity *= 2 }
        return capacity
    }

    /// Includes CPU raw layers/frames and their mips, BOTH GPU mip/raw copies,
    /// per-animation mip/raw staging, mip-building scratch and three CPU colormaps.
    /// sourcePixels additionally reserves 32 bytes per source pixel for PNG decode
    /// (including 16-bit inflate, scanlines and the decoded image). ZIP/JSON bytes,
    /// meshes, driver alignment and other generations are outside this pixel budget.
    public static func pixelStorageBytes(tileSize: Int, layers: Int, animationFrames: Int,
                                         animatedLayers: Int, atlasCapacity: Int? = nil,
                                         sourcePixels: Int = 0) throws -> Int {
        guard tileSize > 0, tileSize <= maxTileSize else { throw ResourcePackValidationError.tileSize(tileSize) }
        guard layers >= 0, layers <= maxLayers else { throw ResourcePackValidationError.layerLimit }
        guard animationFrames >= 0, animatedLayers >= 0, animatedLayers <= layers,
              sourcePixels >= 0 else { throw ResourcePackValidationError.pixelBudget }
        func add(_ a: Int, _ b: Int) throws -> Int {
            let (n, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw ResourcePackValidationError.pixelBudget }
            return n
        }
        func multiply(_ a: Int, _ b: Int) throws -> Int {
            let (n, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow else { throw ResourcePackValidationError.pixelBudget }
            return n
        }
        let capacity = try atlasCapacity ?? Self.atlasCapacity(for: layers)
        guard capacity >= max(1,layers), capacity <= maxLayers else { throw ResourcePackValidationError.layerLimit }
        let raw = tileSize * tileSize * 4, chain = TextureMips.bytes(tileSize,true)
        let copies = try add(try add(layers,capacity),try multiply(animationFrames,2))
        let storage = try multiply(try add(copies,animatedLayers),raw + chain)
        let scratch = raw * 8 + 3 * 65536 * MemoryLayout<Int>.stride
        let total = try add(storage,try add(scratch,try multiply(sourcePixels,32)))
        guard total <= maxPixelBytes else { throw ResourcePackValidationError.pixelBudget }
        return total
    }
}
