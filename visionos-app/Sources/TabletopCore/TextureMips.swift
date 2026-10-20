// Port of quest-app/Assets/Scripts/World/TextureMips.cs at f7d4a0f4536791c0d46ea296d45c1794ffd755e4.
import Foundation

public enum TextureMips {
    public static let cutoff: Float = 0.3

    public static func levels(_ size: Int) -> Int {
        var s = size, n = 1
        while s > 1 { s >>= 1; n += 1 }
        return n
    }
    public static func hasTransparent(_ px: [Color32]) -> Bool { px.contains { $0.a == 0 } }

    /// Bottom-up RGBA levels, including the solidified base, through 1 x 1.
    public static func chain(_ level0: [Color32], _ size: Int) -> [[Color32]] {
        precondition(size > 0 && level0.count == size * size)
        let cutout = hasTransparent(level0)
        var result = [cutout ? solidify(level0, size) : level0]
        let target = cutout ? coverage(result[0], size, cutoff, 1) : 0
        var s = size
        while s > 1 {
            var next = mean(result[result.count - 1], s)
            s = max(1, s >> 1)
            if cutout { scaleToCoverage(&next, s, target, cutoff) }
            result.append(next)
        }
        return result
    }

    public static func solidify(_ src: [Color32], _ size: Int) -> [Color32] {
        precondition(size > 0 && src.count == size * size)
        var dst = src, visited = src.map { $0.a != 0 }
        var queue = src.indices.filter { src[$0].a != 0 }, head = 0
        while head < queue.count {
            let i = queue[head], x = i % size, y = i / size
            head += 1
            for (nx, ny) in [(x+1,y),(x-1,y),(x,y+1),(x,y-1)] {
                guard nx >= 0, ny >= 0, nx < size, ny < size else { continue }
                let n = ny * size + nx
                guard !visited[n] else { continue }
                visited[n] = true
                dst[n] = Color32(dst[i].r, dst[i].g, dst[i].b, 0)
                queue.append(n)
            }
        }
        return dst
    }

    private static func toLinear(_ c: UInt8) -> Float {
        let v = Float(c) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private static func toSrgb(_ linear: Float) -> UInt8 {
        let v: Float = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / Float(2.4)) - 0.055
        return UInt8(max(0, min(255, Int((v * 255).rounded(.toNearestOrEven)))))
    }
    public static func mean(_ src: [Color32], _ size: Int) -> [Color32] {
        precondition(size > 0 && src.count == size * size)
        let n = max(1, size >> 1)
        var dst = [Color32](repeating: Color32(0,0,0,0), count: n*n)
        for y in 0..<n { for x in 0..<n {
            let x0 = min(2*x,size-1), x1 = min(2*x+1,size-1)
            let y0 = min(2*y,size-1), y1 = min(2*y+1,size-1)
            let a = src[y0*size+x0], b = src[y0*size+x1], c = src[y1*size+x0], d = src[y1*size+x1]
            dst[y*n+x] = Color32(
                toSrgb((toLinear(a.r)+toLinear(b.r)+toLinear(c.r)+toLinear(d.r))/4),
                toSrgb((toLinear(a.g)+toLinear(b.g)+toLinear(c.g)+toLinear(d.g))/4),
                toSrgb((toLinear(a.b)+toLinear(b.b)+toLinear(c.b)+toLinear(d.b))/4),
                UInt8((Int(a.a)+Int(b.a)+Int(c.a)+Int(d.a))/4))
        } }
        return dst
    }

    public static func coverage(_ px: [Color32], _ size: Int, _ cutoff: Float, _ scale: Float) -> Float {
        guard size > 1 else { return .nan }
        func alpha(_ i: Int) -> Float { max(0, min(1, Float(px[i].a)/255*scale)) }
        var total: Float = 0
        for y in 0..<(size-1) { for x in 0..<(size-1) {
            let a00 = alpha(y*size+x), a10 = alpha(y*size+x+1)
            let a01 = alpha((y+1)*size+x), a11 = alpha((y+1)*size+x+1)
            var count = 0
            for j in 0..<4 { for i in 0..<4 {
                let fy = (Float(j)+0.5)/4, fx = (Float(i)+0.5)/4
                let v = a00*(1-fx)*(1-fy) + a10*fx*(1-fy) + a01*(1-fx)*fy + a11*fx*fy
                if v > cutoff { count += 1 }
            } }
            total += Float(count)/16
        } }
        return total / Float((size-1)*(size-1))
    }

    public static func scaleToCoverage(_ px: inout [Color32], _ size: Int, _ target: Float, _ cutoff: Float) {
        var lo: Float = 0, hi: Float = 4, scale: Float = 1, best: Float = 1, bestErr = Float.greatestFiniteMagnitude
        for _ in 0..<5 {
            let cov = coverage(px, size, cutoff, scale), err = abs(cov-target)
            if err < bestErr { bestErr = err; best = scale }
            if cov < target { lo = scale }
            else if cov > target { hi = scale }
            else { break }
            scale = (lo+hi)*0.5
        }
        for i in px.indices {
            let a = max(0, min(1, Float(px[i].a)/255*best+0.025))
            px[i].a = UInt8((a*255).rounded(.toNearestOrEven))
        }
    }
    public static func bytes(_ size: Int, _ mips: Bool) -> Int {
        precondition(size > 0)
        var total = 0, s = size
        while true {
            total += s*s*4
            if !mips || s == 1 { return total }
            s = max(1,s >> 1)
        }
    }
}
