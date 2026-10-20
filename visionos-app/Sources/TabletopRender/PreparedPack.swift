#if canImport(Metal)
import Foundation
import Metal
import Synchronization
import TabletopCore

/// Texture contents are initialized on the preparation queue. After publication
/// only GPU commands mutate published textures, including newly appended slices.
final class PreparedPack: @unchecked Sendable {
    static let slicesPerStore = ResourcePackLimits.maxLayers
    struct Animation {
        let layer, firstFrame: Int
        let meta: TextureAnimation
        let staging: any MTLTexture
        let rawStaging: any MTLTexture
        // Format-identical sRGB views for atlas blits; compute uses unorm bases.
        let copyStaging, copyRawStaging: any MTLTexture
    }
    let atlas, nearest: any MTLTexture
    let frames, rawFrames: [any MTLTexture]
    let copyFrames, copyRawFrames: [any MTLTexture]
    let layerNames: [String]
    var layerCount: Int { layerNames.count }
    var capacity: Int { atlas.arrayLength }
    let random: any MTLBuffer
    let animations: [Animation]
    let size: Int
    let uploads: PackTextureUploads?

    private init(atlas: any MTLTexture, nearest: any MTLTexture, frames: [any MTLTexture],
                 rawFrames: [any MTLTexture], copyFrames: [any MTLTexture], copyRawFrames: [any MTLTexture],
                 layerNames: [String], random: any MTLBuffer, animations: [Animation], size: Int,
                 uploads: PackTextureUploads? = nil) {
        self.atlas = atlas; self.nearest = nearest; self.frames = frames; self.rawFrames = rawFrames
        self.copyFrames = copyFrames; self.copyRawFrames = copyRawFrames; self.layerNames = layerNames
        self.random = random; self.animations = animations; self.size = size
        self.uploads = uploads
    }

    static func makeFallback(device: any MTLDevice) throws -> PreparedPack {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,width: 1,height: 1,mipmapped: false)
        d.textureType = .type2DArray; d.arrayLength = 1; d.storageMode = .shared; d.usage = .shaderRead
        guard let atlas = device.makeTexture(descriptor: d) else { throw BatchPreparationError.resourceAllocation }
        var white: UInt32 = .max
        withUnsafeBytes(of: &white) {
            atlas.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,slice: 0,withBytes: $0.baseAddress!,bytesPerRow: 4,bytesPerImage: 4)
        }
        let zeros = [Float](repeating: 0,count: 64*4)
        guard let random = zeros.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!,length: $0.count,options: .storageModeShared) }) else {
            throw BatchPreparationError.resourceAllocation
        }
        return PreparedPack(atlas: atlas,nearest: atlas,frames: [],rawFrames: [],copyFrames: [],copyRawFrames: [],layerNames: [],random: random,animations: [],size: 1)
    }

    /// `extending` is valid only for the same append-only atlas. Existing pixel
    /// data is never read or rewritten; immutable GPU descriptors share old storage.
    static func prepare(_ pack: BakedResourcePack, device: any MTLDevice,
                        extending previous: PreparedPack? = nil) throws -> PreparedPack {
        let size = pack.tileSize, layers = pack.layers.count, levels = TextureMips.levels(size)
        guard size > 0, size <= ResourcePackLimits.maxTileSize, layers <= slicesPerStore,
              pack.layerNames.count == layers, pack.mips.count == layers else { throw BatchPreparationError.invalidGeometry }
        var totalFrames = 0
        for animation in pack.animations {
            guard animation.frames.count <= ResourcePackLimits.maxAnimationFrames,
                  animation.frames.count == animation.meta.imageFrames,
                  animation.meta.frames.count <= ResourcePackLimits.maxAnimationScheduleEntries,
                  animation.layer >= 0, animation.layer < layers,
                  animation.frameMips.count == animation.frames.count else {
                throw BatchPreparationError.invalidGeometry
            }
            let (sum, overflow) = totalFrames.addingReportingOverflow(animation.frames.count)
            guard !overflow else { throw ResourcePackValidationError.pixelBudget }
            totalFrames = sum
        }
        // Validate the full immutable payload before touching any texture slice.
        _ = try ResourcePackLimits.pixelStorageBytes(tileSize: size,layers: layers,
            animationFrames: totalFrames,animatedLayers: pack.animations.count)
        for layer in 0..<layers {
            guard pack.layers[layer].count == size*size, pack.mips[layer].count == levels else {
                throw BatchPreparationError.invalidGeometry
            }
            for level in 0..<levels {
                let n = max(1,size >> level)
                guard pack.mips[layer][level].count == n*n else { throw BatchPreparationError.invalidGeometry }
            }
        }
        for animation in pack.animations {
            for frame in animation.frames.indices {
                guard animation.frames[frame].count == size*size, animation.frameMips[frame].count == levels else {
                    throw BatchPreparationError.invalidGeometry
                }
                for level in 0..<levels {
                    let n = max(1,size >> level)
                    guard animation.frameMips[frame][level].count == n*n else { throw BatchPreparationError.invalidGeometry }
                }
            }
        }
        func texture(_ count: Int, mips: Bool, srgb: Bool, write: Bool = false) throws -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
                                                           width: size, height: size, mipmapped: mips)
            d.textureType = .type2DArray; d.arrayLength = max(1, count)
            d.storageMode = .shared
            d.usage = srgb ? [.shaderRead] : (write ? [.shaderRead, .shaderWrite, .pixelFormatView] : [.shaderRead, .pixelFormatView])
            guard let t = device.makeTexture(descriptor: d) else { throw BatchPreparationError.resourceAllocation }
            return t
        }
        var stagingBuffer: (any MTLBuffer)?, stagedOffset = 0
        var stagedCopies: [PackTextureUploads.Copy] = []
        var sharedAtlas: (any MTLTexture)?, sharedNearest: (any MTLTexture)?
        func upload(_ pixels: [Color32], to texture: any MTLTexture, slice: Int, level: Int) throws {
            let n = max(1, size >> level)
            guard pixels.count == n*n else { throw BatchPreparationError.invalidGeometry }
            if texture === sharedAtlas || texture === sharedNearest {
                // Conservative Metal row/offset alignment, including the tiny mips.
                let row = (n*4 + 255) & ~255, offset = stagedOffset
                guard let stagingBuffer, offset + row*n <= stagingBuffer.length else { throw BatchPreparationError.invalidGeometry }
                let bytes = stagingBuffer.contents().assumingMemoryBound(to: UInt8.self)
                for y in 0..<n { for x in 0..<n {
                    let p = pixels[y*n+x], at = offset+y*row+x*4
                    bytes[at] = p.r; bytes[at+1] = p.g
                    bytes[at+2] = p.b; bytes[at+3] = p.a
                } }
                stagedOffset += row*n
                stagedCopies.append(.init(texture: texture,offset: offset,row: row,size: n,slice: slice,level: level))
                return
            }
            var bytes = [UInt8](); bytes.reserveCapacity(pixels.count*4)
            for p in pixels { bytes.append(contentsOf: [p.r,p.g,p.b,p.a]) }
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0,0,n,n), mipmapLevel: level, slice: slice,
                                withBytes: $0.baseAddress!, bytesPerRow: n*4, bytesPerImage: n*n*4)
            }
        }
        let reusable = previous.flatMap { old -> PreparedPack? in
            guard old.size == size, layers >= old.layerCount, layers <= old.capacity,
                  Array(pack.layerNames.prefix(old.layerCount)) == old.layerNames,
                  pack.animations.count >= old.animations.count,
                  zip(old.animations,pack.animations).allSatisfy({ $0.layer == $1.layer && $0.meta == $1.meta }),
                  pack.animations.dropFirst(old.animations.count).allSatisfy({ $0.layer >= old.layerCount }) else { return nil }
            return old
        }
        // Geometric growth bounds replacement frequency for live palette additions.
        var capacity = 16
        while capacity < layers { capacity *= 2 }
        capacity = min(capacity,slicesPerStore)
        // Reserve spare layers only when the shared total-memory budget permits.
        if (try? ResourcePackLimits.pixelStorageBytes(tileSize: size,layers: reusable?.capacity ?? capacity,
            animationFrames: totalFrames,animatedLayers: pack.animations.count)) == nil {
            if reusable != nil { throw ResourcePackValidationError.pixelBudget }
            capacity = max(1,layers)
        }
        let atlas = try reusable?.atlas ?? texture(capacity, mips: true, srgb: true)
        let nearest = try reusable?.nearest ?? texture(capacity, mips: false, srgb: true)
        if reusable != nil { sharedAtlas = atlas; sharedNearest = nearest }
        let stagedLength = (start: reusable?.layerCount ?? 0, end: layers)
        var uploadBytes = 0
        if reusable != nil {
            for level in 0..<levels {
                let n = max(1,size >> level)
                uploadBytes += ((n*4 + 255) & ~255)*n
            }
            uploadBytes += ((size*4 + 255) & ~255)*size
            uploadBytes *= stagedLength.end - stagedLength.start
            let charged = try ResourcePackLimits.pixelStorageBytes(tileSize: size,layers: layers,
                animationFrames: totalFrames,animatedLayers: pack.animations.count,atlasCapacity: atlas.arrayLength)
            guard uploadBytes + (reusable?.uploads?.pendingByteCount ?? 0) <= ResourcePackLimits.maxPixelBytes - charged else {
                throw ResourcePackValidationError.pixelBudget
            }
            // Fill the shared buffer directly: a temporary full-size byte array
            // plus makeBuffer(bytes:) would double the charged staging memory.
            if uploadBytes > 0 {
                stagingBuffer = device.makeBuffer(length: uploadBytes,options: .storageModeShared)
                guard stagingBuffer != nil else { throw BatchPreparationError.resourceAllocation }
            }
        }
        let startLayer = reusable?.layerCount ?? 0
        func copyView(_ texture: any MTLTexture) throws -> any MTLTexture {
            guard let view = texture.makeTextureView(pixelFormat: .rgba8Unorm_srgb) else {
                throw BatchPreparationError.resourceAllocation
            }
            return view
        }
        if reusable == nil {
            atlas.label = "Tabletop full mip atlas"; nearest.label = "Tabletop point atlas"
        }
        if layers == 0 && reusable == nil {
            for level in 0..<levels {
                let n = max(1,size >> level)
                try upload([Color32](repeating: Color32(255,255,255),count: n*n),to: atlas,slice: 0,level: level)
            }
            try upload([Color32](repeating: Color32(255,255,255),count: size*size),to: nearest,slice: 0,level: 0)
        }
        for layer in startLayer..<layers {
            guard pack.mips[layer].count == levels else { throw BatchPreparationError.invalidGeometry }
            for level in 0..<levels { try upload(pack.mips[layer][level],to: atlas,slice: layer,level: level) }
            try upload(pack.layers[layer],to: nearest,slice: layer,level: 0)
        }
        let addedAnimations = pack.animations.dropFirst(reusable?.animations.count ?? 0)
        let count = addedAnimations.reduce(0) { $0 + $1.frames.count }
        // New stores begin on a logical 2048-slice boundary; old partial stores
        // stay immutable and retain their original addressing.
        var stores = reusable?.frames ?? [], rawStores = reusable?.rawFrames ?? []
        var copies = reusable?.copyFrames ?? [], rawCopies = reusable?.copyRawFrames ?? []
        let firstNewFrame = stores.count*slicesPerStore
        for start in stride(from: 0,to: count,by: slicesPerStore) {
            let slices = min(slicesPerStore,count-start)
            stores.append(try texture(slices,mips: true,srgb: false))
            rawStores.append(try texture(slices,mips: false,srgb: false))
            copies.append(try copyView(stores.last!)); rawCopies.append(try copyView(rawStores.last!))
        }
        var animations = reusable?.animations ?? [], first = firstNewFrame
        for animation in addedAnimations {
            guard animation.layer >= 0, animation.layer < layers,
                  animation.frameMips.count == animation.frames.count else { throw BatchPreparationError.invalidGeometry }
            for frame in animation.frames.indices {
                let at = first+frame, store = at/slicesPerStore, slice = at%slicesPerStore
                guard animation.frameMips[frame].count == levels else { throw BatchPreparationError.invalidGeometry }
                for level in 0..<levels { try upload(animation.frameMips[frame][level],to: stores[store],slice: slice,level: level) }
                try upload(animation.frames[frame],to: rawStores[store],slice: slice,level: 0)
            }
            let staging = try texture(1,mips: true,srgb: false,write: true)
            let rawStaging = try texture(1,mips: false,srgb: false,write: true)
            animations.append(Animation(layer: animation.layer,firstFrame: first,meta: animation.meta,
                                        staging: staging,rawStaging: rawStaging,
                                        copyStaging: try copyView(staging),copyRawStaging: try copyView(rawStaging)))
            first += animation.frames.count
        }
        var random = [Float](repeating: 0,count: 64*4)
        for i in 0..<min(random.count,pack.randomTables.count) { random[i] = pack.randomTables[i] }
        guard let buffer = random.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!,length: $0.count,options: .storageModeShared) }) else {
            throw BatchPreparationError.resourceAllocation
        }
        var uploads = reusable?.uploads
        if !stagedCopies.isEmpty {
            guard let staging = stagingBuffer, stagedOffset == uploadBytes,
                  let event = device.makeSharedEvent() else { throw BatchPreparationError.resourceAllocation }
            uploads = PackTextureUploads(buffer: staging,copies: stagedCopies,previous: uploads,event: event)
        }
        return PreparedPack(atlas: atlas,nearest: nearest,frames: stores,rawFrames: rawStores,
                            copyFrames: copies,copyRawFrames: rawCopies,layerNames: pack.layerNames,
                            random: buffer,animations: animations,size: size,uploads: uploads)
    }
}

/// Append transactions form a dependency chain so a skipped mailbox publication
/// cannot lose slices. Mutable cursors are protected independently of preparation.
/// The event also orders a reopened renderer's queue after a prior queue's upload.
final class PackTextureUploads: @unchecked Sendable {
    struct Copy {
        let texture: any MTLTexture
        let offset, row, size, slice, level: Int
    }
    private struct State: @unchecked Sendable {
        var buffer: (any MTLBuffer)?
        var copies: [Copy]
        var previous: PackTextureUploads?
        var cursor = 0
        var enqueued = false
        var serial: UInt64 = 0
    }
    private let state: Mutex<State>
    private let event: any MTLSharedEvent
    init(buffer: any MTLBuffer, copies: [Copy], previous: PackTextureUploads?, event: any MTLSharedEvent) {
        state = Mutex(State(buffer: buffer,copies: copies,previous: previous)); self.event = event
    }
    var pendingByteCount: Int {
        state.withLock { ($0.buffer?.length ?? 0) + ($0.previous?.pendingByteCount ?? 0) }
    }
    /// Called before animation and drawing. Incomplete uploads keep the prior
    /// draw scene visible; the command buffer retains each staging buffer it uses.
    func encode(commands: any MTLCommandBuffer, deadline: ContinuousClock.Instant) -> Bool {
        state.withLockIfAvailable { state in
            if state.serial > 0 { commands.encodeWaitForEvent(event,value: state.serial) }
            if state.enqueued {
                return true
            }
            if let previous = state.previous, !previous.encode(commands: commands,deadline: deadline) { return false }
            guard ContinuousClock.now < deadline, let buffer = state.buffer,
                  let blit = commands.makeBlitCommandEncoder() else { return false }
            while state.cursor < state.copies.count, ContinuousClock.now < deadline {
                let copy = state.copies[state.cursor]
                blit.copy(from: buffer,sourceOffset: copy.offset,sourceBytesPerRow: copy.row,sourceBytesPerImage: copy.row*copy.size,
                    sourceSize: MTLSize(width: copy.size,height: copy.size,depth: 1),to: copy.texture,
                    destinationSlice: copy.slice,destinationLevel: copy.level,destinationOrigin: MTLOrigin(x: 0,y: 0,z: 0))
                state.cursor += 1
            }
            blit.endEncoding()
            state.serial += 1
            commands.encodeSignalEvent(event,value: state.serial)
            guard state.cursor == state.copies.count else { return false }
            state.enqueued = true
            state.buffer = nil; state.copies = []; state.previous = nil
            return true
        } ?? false
    }
}

struct AnimationShown: Sendable {
    var frame = -1, next = -1, blend = -1
}

/// Each mailbox owns fresh array storage, prepared away from the render thread.
struct PreparedDrawScene: Sendable {
    let generation: UInt64
    let pack: PreparedPack?
    var batches: [PreparedBatch]
    var transparent: [PreparedBatch]
    var shown: [AnimationShown]
    init(generation: UInt64, batches: [SIMD3<Int>: PreparedBatch], pack: PreparedPack?) {
        self.generation = generation; self.pack = pack
        self.batches = batches.values.filter { $0.indexCount > 0 }.sorted {
            if $0.boundsMax.y != $1.boundsMax.y { return $0.boundsMax.y > $1.boundsMax.y }
            return BatchOrder.farther($0.boundsMin, $0.key, $1.boundsMin, $1.key, eye: .zero)
        }
        transparent = self.batches.filter { !$0.ranges.transparent.isEmpty || !$0.ranges.waterBack.isEmpty }
        shown = [AnimationShown](repeating: AnimationShown(),count: pack?.animations.count ?? 0)
    }
}
#endif
