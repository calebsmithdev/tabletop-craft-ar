// Port of quest-app/Assets/Scripts/World/ResourcePackAtlas{,.Models}.cs at f7d4a0f4536791c0d46ea296d45c1794ffd755e4.
// CPU data only. The serial-owner builder is intentionally NOT Sendable; workers receive baked() values.
import Foundation

public struct BakedResourcePack: IFaceSource, IModelSource, Sendable {
    public let faces: [String: [FaceKey]]
    public let models: [String: BakedModel]
    public let shapeOverrides: [String: BlockShape]
    public let tileSize: Int
    public let layerNames: [String]
    public let layers: [[Color32]]
    public let mips: [[[Color32]]]
    public let animations: [ResourcePackAtlasAnimation]
    public let solidLayers: Set<Int>
    public let randomUv: RandomUv
    public let randomTables: [Float]
    public let colormaps: BiomeColormaps

    public func face(_ state: String, _ dir: Int) -> FaceKey {
        guard (0..<6).contains(dir), let found = faces[state] else { return FaceKey(layer: -1,color: BlockRules.flatColor(state)) }
        return found[dir]
    }
    public func model(_ state: String) -> BakedModel? { models[state] }
}

public final class ResourcePackAtlas: IModelAssets {
    public private(set) var tileSize = 16
    public let referenceProfile: Bool
    public private(set) var layerNames: [String] = []
    /// Sticky validation failure. Task cancellation never invalidates the pack.
    public private(set) var validationError: ResourcePackValidationError?
    // A face/model resolution mutates several related caches. Finish that bounded
    // transaction before observing cancellation, then resume at the next state.
    private var resolutionDepth = 0
    private let archive: ZipArchive
    private var layers: [String: Int] = [:], quadLayers: [String: Int] = [:]
    private var pixels: [[Color32]] = []
    // Cache mip chains once so successive baked values share COW storage with the owner.
    private var mipPixels: [[[Color32]]] = []
    private var animationFrameCount = 0
    private var faceCache: [String: [FaceKey]] = [:]
    private var modelCache: [String: JSONObject] = [:]
    private var missingModels: Set<String> = []
    private var alphaClasses: [Int: Int] = [:]
    private var solidLayers: Set<Int> = []
    var animations: [ResourcePackAtlasAnimation] = []
    private let colormaps: BiomeColormaps

    // BlockModels retains IModelAssets. This forwarding view avoids an atlas -> models -> atlas cycle.
    private final class Assets: IModelAssets {
        unowned let atlas: ResourcePackAtlas
        init(_ atlas: ResourcePackAtlas) { self.atlas = atlas }
        func readJson(_ path: String) -> JSONObject? { atlas.readJson(path) }
        func texture(_ texture: String, _ tinted: Bool, _ state: String) -> FaceKey { atlas.texture(texture,tinted,state) }
        func alphaClass(_ layer: Int) -> Int { atlas.alphaClass(layer) }
    }
    private lazy var blockModels = BlockModels(Assets(self))
    public var blockEntityBoxes: Bool {
        get { blockModels.entityBoxes }
        set { blockModels.entityBoxes = newValue }
    }

    /// referenceProfile reproduces Tests~/PackAssets.cs, whose layer numbering differs from the production atlas.
    public init(path: String, referenceProfile: Bool = false) throws {
        archive = try ZipArchive(path: path)
        self.referenceProfile = referenceProfile
        colormaps = referenceProfile ? BiomeColormaps() : try Self.loadColormaps(archive)
    }
    public func readBytes(_ path: String) -> [UInt8]? {
        guard canLoad() else { return nil }
        return try? archive.read(path)
    }
    public func readJson(_ path: String) -> JSONObject? {
        guard let bytes = readBytes(path), let text = String(bytes: bytes,encoding: .utf8),
              let object = try? PackJSON.parse(text) else { return nil }
        return object
    }

    public func prewarm(_ palette: [String]) {
        guard canLoad() else { return }
        if !referenceProfile {
            // TabletopRenderer.Prewarm: calls alternate canonical fluids for each direction, then the pseudo-states.
            for d in 0..<6 {
                guard canLoad() else { return }
                _ = face("minecraft:water",d); _ = face("minecraft:lava",d)
            }
            _ = face("minecraft:water[tabletop=flow]",4)
            _ = face("minecraft:lava[tabletop=flow]",4)
            _ = face("minecraft:water[tabletop=overlay]",4)
        }
        for state in palette {
            guard canLoad() else { return }
            for d in 0..<6 { _ = face(state,d) }
        }
    }
    public func checkedPrewarm(_ palette: [String]) throws {
        prewarm(palette)
        if Task.isCancelled { throw ResourcePackValidationError.cancelled }
        if let validationError { throw validationError }
    }
    public func face(_ state: String, _ dir: Int) -> FaceKey {
        precondition((0..<6).contains(dir))
        guard canLoad() else { return FaceKey(layer: -1,color: BlockRules.flatColor(state)) }
        if let found = faceCache[state] { return found[dir] }
        resolutionDepth += 1
        defer { resolutionDepth -= 1 }
        var faces = [FaceKey](repeating: FaceKey(layer: -1,color: BlockRules.flatColor(state)),count: 6)
        // Resolving first allocates production layer IDs, even when Prepare replaces all cube faces.
        if !referenceProfile { resolve(state,&faces) }
        guard canLoad() else { return FaceKey(layer: -1,color: BlockRules.flatColor(state)) }
        _ = blockModels.prepare(state,&faces)
        faceCache[state] = faces
        return faces[dir]
    }
    public func baked() -> BakedResourcePack {
        var models: [String: BakedModel] = [:]
        for state in faceCache.keys {
            guard canLoad() else { break }
            if let model = blockModels.model(state) { models[state] = model }
        }
        let uv = blockModels.randomUv
        return BakedResourcePack(faces: faceCache,models: models,shapeOverrides: blockModels.shapeOverrides,
                                 tileSize: tileSize,layerNames: layerNames,layers: pixels,
                                 mips: mipPixels,animations: animations,
                                 solidLayers: solidLayers,randomUv: uv,randomTables: uv.packed(),colormaps: colormaps)
    }
    public func checkedBaked() throws -> BakedResourcePack {
        if Task.isCancelled { throw ResourcePackValidationError.cancelled }
        if let validationError { throw validationError }
        let result = baked()
        if Task.isCancelled { throw ResourcePackValidationError.cancelled }
        if let validationError { throw validationError }
        return result
    }

    /// Budget for current contents, including requested additions, before allocating them.
    func checkPixelBudget(layers: Int, addingFrames: Int = 0, addingAnimations: Int = 0,
                          sourcePixels: Int = 0) -> Bool {
        guard canLoad() else { return false }
        do {
            _ = try ResourcePackLimits.pixelStorageBytes(tileSize: tileSize,layers: layers,
                animationFrames: animationFrameCount + addingFrames,
                animatedLayers: animations.count + addingAnimations,sourcePixels: sourcePixels)
            return true
        } catch let error as ResourcePackValidationError { fail(error); return false }
        catch { fail(.pixelBudget); return false }
    }
    func fail(_ error: ResourcePackValidationError) {
        guard error != .cancelled else { return }
        if validationError == nil { validationError = error }
    }
    func canLoad() -> Bool {
        validationError == nil && (resolutionDepth > 0 || !Task.isCancelled)
    }
    func recordAnimation(_ animation: ResourcePackAtlasAnimation) {
        animationFrameCount += animation.frames.count
        animations.append(animation)
    }

    private static func loadColormaps(_ archive: ZipArchive) throws -> BiomeColormaps {
        func read(_ name: String) throws -> [Int]? {
            if Task.isCancelled { throw ResourcePackValidationError.cancelled }
            guard let bytes = try? archive.read("assets/minecraft/textures/colormap/\(name).png"),
                  let size = TextureAnimation.pngSize(bytes), size.width == 256, size.height == 256,
                  let image = PngDecoder.decode(bytes) else { return nil }
            var map = [Int](repeating: 0,count: 65536)
            for y in 0..<256 {
                if Task.isCancelled { throw ResourcePackValidationError.cancelled }
                for x in 0..<256 {
                    let c = image.pixels[(255-y)*256+x]
                    map[y*256+x] = Int(c.r) << 16 | Int(c.g) << 8 | Int(c.b)
                }
            }
            return map
        }
        return try BiomeColormaps(grass: read("grass"),foliage: read("foliage"),dryFoliage: read("dry_foliage"))
    }
    public func texture(_ texture: String, _ tinted: Bool, _ state: String) -> FaceKey {
        guard canLoad() else { return FaceKey(layer: -1,color: BlockRules.flatColor(state)) }
        resolutionDepth += 1
        defer { resolutionDepth -= 1 }
        return key(texture,tinted,state)
    }
    public func alphaClass(_ layer: Int) -> Int {
        guard layer >= 0, layer < pixels.count else { return 0 }
        if let cached = alphaClasses[layer] { return cached }
        let result = Self.classifyAlpha(pixels[layer])
        alphaClasses[layer] = result
        return result
    }
    private static func classifyAlpha(_ px: [Color32]) -> Int {
        var result = 0
        for p in px where p.a != 255 { if p.a != 0 { return 2 }; result = 1 }
        return result
    }
    private static let dirNames = ["west","east","down","up","north","south"]
    private static let grassTint = Color32(124,189,107), foliageTint = Color32(89,174,48), waterTint = Color32(63,118,228,200)

    private func resolve(_ state: String, _ faces: inout [FaceKey]) {
        let name = BlockRules.name(state), path = BlockRules.path(state), ns = Self.resource(name).ns
        if (path == "water" || path == "lava") && state.contains("tabletop=") {
            let overlay = state.contains("tabletop=overlay"), tex = "\(ns):block/\(path)_\(overlay ? "overlay" : "flow")"
            let quad = overlay ? -1 : quadLayer(tex)
            var k = key(tex,false,state,quad >= 0 ? quad : nil)
            if quad >= 0 { k.random = 64 } // FluidRules.QuadTable
            faces = [FaceKey](repeating: k,count: 6)
            return
        }
        let bsPath = "assets/\(ns)/blockstates/\(path).json"
        guard let bs = readJson(bsPath) else { return }
        var model: String?
        if let variants = bs.o("variants") {
            let props = state.firstIndex(of: "[").map { String(state[state.index(after: $0)...]).trimmingCharacters(in: CharacterSet(charactersIn: "]")) } ?? ""
            var pick: JSONValue?
            for key in PackJSON.keys(variants) {
                let matches = key.isEmpty || key.split(separator: ",").allSatisfy { (","+props+",").contains(","+$0+",") }
                if pick == nil || matches { pick = variants[key]; if matches { break } }
            }
            model = Self.modelName(pick)
        } else if let part = bs.a("multipart")?.first?.objectValue { model = Self.modelName(part["apply"]) }
        guard let model else { return }
        var textures: [String: String] = [:], elements: [JSONValue]?, cur: String? = model
        for _ in 0..<12 {
            guard let id = cur, let json = modelJson(id) else { break }
            if let defs = json.o("textures") {
                for (key,value) in PackJSON.members(defs) where textures[key] == nil { textures[key] = value.stringValue ?? value.objectValue?.s("sprite") }
            }
            if elements == nil { elements = json.a("elements") }
            cur = json.s("parent")
        }
        if elements?.isEmpty != false {
            let tex = Self.lookup(textures,"#cross") ?? Self.lookup(textures,"#all") ?? Self.lookup(textures,"#texture")
                ?? ((path == "water" || path == "lava") ? Self.lookup(textures,"#particle") : nil)
            if let tex { faces = [FaceKey](repeating: key(tex,false,state),count: 6) }
            return
        }
        guard let defs = elements?.first?.objectValue?.o("faces") else { return }
        for i in 0..<6 {
            guard let f = defs.o(Self.dirNames[i]), let tex = Self.lookup(textures,f.s("texture")) else { continue }
            faces[i] = key(tex,f["tintindex"] != nil && BiomeColors.tinted(state,f.i("tintindex",-1)),state)
        }
    }
    private static func resource(_ id: String) -> (ns: String, path: String) {
        guard let c = id.firstIndex(of: ":") else { return ("minecraft",id) }
        return (String(id[..<c]),String(id[id.index(after: c)...]))
    }
    private static func modelName(_ value: JSONValue?) -> String? {
        (value?.arrayValue?.first ?? value)?.objectValue?.s("model")
    }
    private static func lookup(_ textures: [String: String], _ ref: String?) -> String? {
        var r = ref
        for _ in 0..<8 { guard let value = r, value.hasPrefix("#") else { break }; r = textures[String(value.dropFirst())] }
        return r?.hasPrefix("#") == true ? nil : r
    }
    private func modelJson(_ id: String) -> JSONObject? {
        if id.hasPrefix("builtin/") { return nil }
        let (ns,p) = Self.resource(id), key = ns+":"+p
        if let hit = modelCache[key] { return hit }
        if missingModels.contains(key) { return nil }
        guard let json = readJson("assets/\(ns)/models/\(p).json") else { missingModels.insert(key); return nil }
        modelCache[key] = json
        return json
    }
    private func key(_ tex: String, _ tinted: Bool, _ state: String, _ layer: Int? = nil) -> FaceKey {
        let l = layer ?? self.layer(tex), p = BlockRules.path(state), white = Color32(255,255,255)
        var color = white, kind: TintKind = .none
        if tinted || (!referenceProfile && (p == "water" || p == "bubble_column")) {
            let tint = BiomeColors.blockTint(state)
            kind = tint.0
            color = tint.1 ?? (referenceProfile ? (kind == .none ? white : Self.grassTint) :
                kind == .water ? Self.waterTint : kind == .foliage ? Self.foliageTint : kind == .none ? white : Self.grassTint)
        }
        var result = FaceKey(layer: l,color: l < 0 ? BlockRules.flatColor(state) : color)
        result.tint = l < 0 ? .none : kind
        return result
    }
    private func layer(_ texture: String) -> Int {
        guard canLoad() else { return -1 }
        let (ns,p) = Self.resource(texture), cacheKey = referenceProfile ? ns+":"+p : texture
        if let l = layers[cacheKey] { return l }
        let entry = "assets/\(ns)/textures/\(p).png"
        guard let loaded = readTexture(entry,layerCount: pixels.count + 1) else { layers[cacheKey] = -1; return -1 }
        let (bytes,image,meta) = loaded
        let l = pixels.count
        guard let px = loadPixels(image,meta,l), canLoad() else { return -1 }
        let mips = TextureMips.chain(px,tileSize)
        guard canLoad() else { return -1 }
        pixels.append(px); mipPixels.append(mips); layerNames.append(cacheKey)
        if referenceProfile {
            // ZipAssets.AlphaOf scans every column of the top min(width,height) rows, and treats any RGB/grey tRNS as cutout.
            let top = image.pixels.suffix(image.width*min(image.width,image.height))
            var alpha = Self.classifyAlpha(Array(top))
            if bytes.count > 25, bytes[25] == 0 || bytes[25] == 2 {
                var pos = 8, hasTrns = false
                while pos+12 <= bytes.count {
                    let len = pngBE32(bytes,pos)
                    guard len <= bytes.count-pos-12 else { break }
                    if String(decoding: bytes[(pos+4)..<(pos+8)],as: UTF8.self) == "tRNS" { hasTrns = true; break }
                    pos += len+12
                }
                alpha = hasTrns ? 1 : 0
            }
            alphaClasses[l] = alpha
            if alpha == 0 { solidLayers.insert(l) }
        } else { publishSolid(l) }
        layers[cacheKey] = l
        return l
    }
    private func quadLayer(_ texture: String) -> Int {
        guard canLoad() else { return -1 }
        if let l = quadLayers[texture] { return l }
        let (ns,p) = Self.resource(texture), entry = "assets/\(ns)/textures/\(p).png"
        var l = -1
        if !pixels.isEmpty, let loaded = readTexture(entry,layerCount: pixels.count + 4,quad: true) {
            let (_,image,meta) = loaded
            l = pixels.count
            for q in 0..<4 {
                guard canLoad(), let px = loadPixels(image,meta,pixels.count,q), canLoad() else { return -1 }
                let mips = TextureMips.chain(px,tileSize)
                guard canLoad() else { return -1 }
                pixels.append(px); mipPixels.append(mips); layerNames.append(texture+"#\(q)"); publishSolid(pixels.count-1)
            }
        }
        quadLayers[texture] = l
        return l
    }

    /// Check dimensions, animation expansion and the complete prospective allocation
    /// before decoding even the first source image or cropping any animation frames.
    private func readTexture(_ entry: String, layerCount: Int, quad: Bool = false)
        -> (bytes: [UInt8], image: PngDecoder.Image, meta: TextureAnimation?)? {
        guard canLoad(), let bytes = readBytes(entry), let size = TextureAnimation.pngSize(bytes) else { return nil }
        if quad && (size.width != 2*tileSize || size.height < size.width) { return nil }
        if pixels.isEmpty {
            guard size.width <= ResourcePackLimits.maxTileSize else { fail(.tileSize(size.width)); return nil }
            tileSize = size.width
        }
        guard size.width <= 8192, size.height <= 8192 else { return nil }
        let meta: TextureAnimation?
        do {
            if let metadata = readBytes(entry+".mcmeta"), let text = String(bytes: metadata,encoding: .utf8) {
                meta = try TextureAnimation.parseChecked(text,size.width,size.height)
            } else { meta = nil }
        } catch let error as ResourcePackValidationError { fail(error); return nil }
        catch { return nil }
        let adding = layerCount - pixels.count
        guard checkPixelBudget(layers: layerCount,addingFrames: (meta?.imageFrames ?? 0)*adding,
                               addingAnimations: meta == nil ? 0 : adding,sourcePixels: size.width*size.height),
              let image = PngDecoder.decode(bytes), canLoad() else { return nil }
        return (bytes,image,meta)
    }
    private func publishSolid(_ layer: Int) {
        guard pixels[layer].allSatisfy({ $0.a == 255 }),
              animations.filter({ $0.layer == layer }).allSatisfy({ $0.frames.allSatisfy { $0.allSatisfy { $0.a == 255 } } }) else { return }
        solidLayers.insert(layer)
    }

}
