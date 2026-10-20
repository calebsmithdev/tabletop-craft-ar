// CPU port of quest-app/Assets/Scripts/World/ResourcePackAtlas.Animation.cs at f7d4a0f4536791c0d46ea296d45c1794ffd755e4.
import Foundation

public struct ResourcePackAtlasAnimation: Sendable {
    public let layer: Int
    public let meta: TextureAnimation
    /// All image frames, including frames the playback schedule does not reference.
    public let frames: [[Color32]]
    public let frameMips: [[[Color32]]]

    /// Every mip is blended independently, at the C# renderer's 1/255 precision.
    /// Alpha comes from the current frame; RGB interpolation is in encoded space, like vanilla.
    public func mips(at tick: Int64) -> [[Color32]] {
        let (f,next,blend) = meta.at(tick), b = Int(blend*255)
        if b == 0 { return frameMips[f] }
        let ib = 255-b
        return zip(frameMips[f],frameMips[next]).map { current, upcoming in
            zip(current,upcoming).map { c,d in
                Color32(UInt8((Int(c.r)*ib+Int(d.r)*b)/255),UInt8((Int(c.g)*ib+Int(d.g)*b)/255),
                        UInt8((Int(c.b)*ib+Int(d.b)*b)/255),c.a)
            }
        }
    }
}

extension ResourcePackAtlas {
    func loadPixels(_ image: PngDecoder.Image, _ meta: TextureAnimation?, _ layer: Int, _ part: Int = -1) -> [Color32]? {
        guard canLoad() else { return nil }
        if let meta {
            // Tiny animation cells cannot be split into four fluid quadrants.
            // Preserve the static-quarter fallback for that malformed metadata.
            if part < 0 || (meta.frameWidth >= 2 && meta.frameHeight >= 2) {
                var frames: [[Color32]] = [], frameMips: [[[Color32]]] = []
                for i in 0..<meta.imageFrames {
                    guard canLoad() else { return nil }
                    var (fx,fy) = meta.origin(i)
                    var fw = meta.frameWidth, fh = meta.frameHeight
                    if part >= 0 { fw /= 2; fh /= 2; fx += (part & 1)*fw; fy += (part >> 1)*fh }
                    let px = Self.crop(image.pixels,image.width,image.height,fx,fy,fw,fh,tileSize)
                    frames.append(px)
                    frameMips.append(TextureMips.chain(px,tileSize))
                    guard canLoad() else { return nil }
                }
                recordAnimation(ResourcePackAtlasAnimation(layer: layer,meta: meta,frames: frames,frameMips: frameMips))
                return frames[meta.frames[0].index]
            }
        }
        let extent = min(image.width,image.height)
        return Self.crop(image.pixels,image.width,image.height,
            part < 0 ? 0 : (part & 1)*tileSize,part < 0 ? 0 : (part >> 1)*tileSize,
            part < 0 ? extent : tileSize,part < 0 ? extent : tileSize,tileSize)
    }

    /// Source and destination rows are bottom-up; fx/fy refer to top-left image coordinates.
    public static func crop(_ src: [Color32], _ w: Int, _ h: Int, _ fx: Int, _ fy: Int,
                            _ fw: Int, _ fh: Int, _ size: Int) -> [Color32] {
        precondition(w > 0 && h > 0 && src.count == w*h && size > 0 && fw > 0 && fh > 0 &&
                     fx >= 0 && fy >= 0 && fx+fw <= w && fy+fh <= h)
        let bottom = h-fy-fh
        var dst = [Color32](repeating: Color32(0,0,0,0),count: size*size)
        for y in 0..<size { for x in 0..<size { dst[y*size+x] = src[(bottom+y*fh/size)*w+fx+x*fw/size] } }
        return dst
    }

    /// Standalone cancellable crop. Atlas resolutions use atomic crops so a task
    /// cannot leave their layer/model caches partially populated.
    static func checkedCrop(_ src: [Color32], _ w: Int, _ h: Int, _ fx: Int, _ fy: Int,
                            _ fw: Int, _ fh: Int, _ size: Int) throws -> [Color32] {
        precondition(w > 0 && h > 0 && src.count == w*h && size > 0 && fw > 0 && fh > 0 &&
                     fx >= 0 && fy >= 0 && fx+fw <= w && fy+fh <= h)
        if Task.isCancelled { throw ResourcePackValidationError.cancelled }
        let bottom = h-fy-fh
        var dst = [Color32](repeating: Color32(0,0,0,0),count: size*size)
        for y in 0..<size {
            if Task.isCancelled { throw ResourcePackValidationError.cancelled }
            for x in 0..<size { dst[y*size+x] = src[(bottom+y*fh/size)*w+fx+x*fw/size] }
        }
        return dst
    }
}
