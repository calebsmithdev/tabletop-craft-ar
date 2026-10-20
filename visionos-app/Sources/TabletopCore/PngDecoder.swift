// Port of quest-app/Assets/Scripts/World/PngDecoder.cs at f7d4a0f4536791c0d46ea296d45c1794ffd755e4.
// Pure CPU PNG decoding. Returned pixels have row zero at the bottom, like the C# decoder.
public enum PngDecoder {
    public struct Image: Sendable, Equatable {
        public let pixels: [Color32]
        public let width, height: Int
    }
    public static func decode(_ png: [UInt8]) -> Image? {
        guard png.count >= 33, Array(png[0..<8]) == [137,80,78,71,13,10,26,10] else { return nil }
        var pos = 8, w = 0, h = 0, depth = 0, type = -1
        var palette: [UInt8] = [], trns: [UInt8] = [], idat: [UInt8] = []
        var header = false, ended = false
        while pos+12 <= png.count {
            let len = pngBE32(png,pos), d = pos+8
            guard len <= png.count-pos-12 else { return nil }
            let chunk = String(decoding: png[(pos+4)..<(pos+8)],as: UTF8.self)
            if !header && chunk != "IHDR" { return nil }
            switch chunk {
            case "IHDR":
                guard !header, len == 13 else { return nil }
                w = pngBE32(png,d); h = pngBE32(png,d+4); depth = Int(png[d+8]); type = Int(png[d+9])
                guard w > 0, h > 0, w <= 8192, h <= 8192, png[d+10] == 0, png[d+11] == 0, png[d+12] == 0 else { return nil }
                header = true
            case "PLTE": palette = Array(png[d..<(d+len)])
            case "tRNS": trns = Array(png[d..<(d+len)])
            case "IDAT": idat.append(contentsOf: png[d..<(d+len)])
            case "IEND": ended = true
            default: break
            }
            if ended { break }
            pos = d+len+4
        }
        let channels: Int
        switch type {
        case 0: guard [1,2,4,8,16].contains(depth) else { return nil }; channels = 1
        case 3: guard [1,2,4,8].contains(depth), !palette.isEmpty else { return nil }; channels = 1
        case 2,4,6:
            guard depth == 8 || depth == 16 else { return nil }
            channels = type == 2 ? 3 : type == 4 ? 2 : 4
        default: return nil
        }
        guard header, ended, !idat.isEmpty else { return nil }
        let bitsPerPixel = channels*depth, bpp = max(1,bitsPerPixel/8), stride = (w*bitsPerPixel+7)/8
        guard let raw = try? inflateBytes(idat,size: (stride+1)*h,raw: false) else { return nil }
        var cur = [UInt8](repeating: 0,count: stride), prev = cur
        var px = [Color32](repeating: Color32(0,0,0,0),count: w*h)
        for y in 0..<h {
            let f = raw[y*(stride+1)]
            guard f <= 4 else { return nil }
            for i in 0..<stride {
                let left = i >= bpp ? Int(cur[i-bpp]) : 0, up = Int(prev[i]), ul = i >= bpp ? Int(prev[i-bpp]) : 0
                var value = Int(raw[y*(stride+1)+1+i])
                switch f {
                case 1: value += left
                case 2: value += up
                case 3: value += (left+up) >> 1
                case 4:
                    let p = left+up-ul, pa = abs(p-left), pb = abs(p-up), pc = abs(p-ul)
                    value += pa <= pb && pa <= pc ? left : pb <= pc ? up : ul
                default: break
                }
                cur[i] = UInt8(truncatingIfNeeded: value)
            }
            for x in 0..<w { px[(h-1-y)*w+x] = pixel(cur,x,type,depth,palette,trns) }
            swap(&prev,&cur)
        }
        return Image(pixels: px,width: w,height: h)
    }
    private static func sample(_ row: [UInt8], _ index: Int, _ depth: Int) -> Int {
        if depth == 8 { return Int(row[index]) }
        if depth == 16 { return Int(row[index*2]) }
        let perByte = 8/depth, shift = 8-depth*(index%perByte+1)
        return (Int(row[index/perByte]) >> shift) & ((1 << depth)-1)
    }
    private static func pixel(_ row: [UInt8], _ x: Int, _ type: Int, _ depth: Int, _ palette: [UInt8], _ trns: [UInt8]) -> Color32 {
        let s = depth == 16 ? 2 : 1
        switch type {
        case 0:
            let raw = sample(row,x,depth), g = UInt8(depth >= 8 ? raw : raw*255/((1 << depth)-1))
            let full = depth == 16 ? Int(row[x*2]) << 8 | Int(row[x*2+1]) : raw
            let transparent = trns.count >= 2 && pngBE16(trns,0) == full
            return Color32(g,g,g,transparent ? 0 : 255)
        case 3:
            let i = sample(row,x,depth)
            guard i*3+2 < palette.count else { return Color32(0,0,0,0) }
            return Color32(palette[i*3],palette[i*3+1],palette[i*3+2],i < trns.count ? trns[i] : 255)
        case 2:
            let o = x*3*s
            var c = Color32(row[o],row[o+s],row[o+2*s])
            // Match the C# decoder: RGB tRNS is implemented for 8-bit images only.
            if depth == 8, trns.count >= 6, trns[1] == c.r, trns[3] == c.g, trns[5] == c.b { c.a = 0 }
            return c
        case 4:
            let o = x*2*s
            return Color32(row[o],row[o],row[o],row[o+s])
        default:
            let o = x*4*s
            return Color32(row[o],row[o+s],row[o+2*s],row[o+3*s])
        }
    }
}
private func pngBE16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i+1]) }
func pngBE32(_ b: [UInt8], _ i: Int) -> Int { pngBE16(b,i) << 16 | pngBE16(b,i+2) }
