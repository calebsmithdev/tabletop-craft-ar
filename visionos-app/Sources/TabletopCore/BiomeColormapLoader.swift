// Port of quest-app/Assets/Scripts/World/BiomeColormapLoader.cs at f7d4a0f4536791c0d46ea296d45c1794ffd755e4.
public enum BiomeColormapLoader {
    public static func load(_ zip: ZipArchive) -> BiomeColormaps {
        BiomeColormaps(grass: read(zip,"grass"),foliage: read(zip,"foliage"),dryFoliage: read(zip,"dry_foliage"))
    }
    /// 0xRRGGBB in PNG order (top row first), the order ColorMapColorUtil indexes.
    public static func read(_ zip: ZipArchive, _ name: String) -> [Int]? {
        guard let bytes = try? zip.read("assets/minecraft/textures/colormap/\(name).png"),
              let image = PngDecoder.decode(bytes), image.width == 256, image.height == 256 else { return nil }
        var map = [Int](repeating: 0,count: 65536)
        for y in 0..<256 { for x in 0..<256 {
            let c = image.pixels[(255-y)*256+x]
            map[y*256+x] = Int(c.r) << 16 | Int(c.g) << 8 | Int(c.b)
        } }
        return map
    }
}
