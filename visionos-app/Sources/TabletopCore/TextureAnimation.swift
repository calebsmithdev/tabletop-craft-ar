// Port of quest-app/Assets/Scripts/World/TextureAnimation.cs at f7d4a0f4536791c0d46ea296d45c1794ffd755e4.
public struct TextureAnimation: Sendable, Equatable {
    public static let ticksPerSecond = 20
    public struct Frame: Sendable, Equatable {
        public let index: Int
        public let time: Int
    }
    public let frames: [Frame]
    public let interpolate: Bool
    public let frameWidth, frameHeight, columns, imageFrames, cycleTicks: Int

    public static func parse(_ mcmetaJson: String, _ imageWidth: Int, _ imageHeight: Int) -> TextureAnimation? {
        try? parseChecked(mcmetaJson,imageWidth,imageHeight)
    }

    /// Malformed/non-animated metadata retains the static-image fallback; resource-limit
    /// violations throw so the atlas cannot silently accept an animation bomb as static.
    public static func parseChecked(_ mcmetaJson: String, _ imageWidth: Int, _ imageHeight: Int) throws -> TextureAnimation? {
        guard imageWidth > 0, imageHeight > 0,
              let root = try? Json.parse(mcmetaJson).objectValue, let anim = root.o("animation") else { return nil }
        let fw: Int, fh: Int
        if anim["width"] != nil { fw = anim.i("width"); fh = anim["height"] != nil ? anim.i("height") : imageHeight }
        else if anim["height"] != nil { fw = imageWidth; fh = anim.i("height") }
        else { fw = min(imageWidth,imageHeight); fh = fw }
        guard fw > 0, fh > 0, imageWidth % fw == 0, imageHeight % fh == 0 else { return nil }
        let columns = imageWidth/fw
        let (count, overflow) = columns.multipliedReportingOverflow(by: imageHeight/fh)
        guard !overflow, count > 0 else { return nil }
        guard count <= ResourcePackLimits.maxAnimationFrames else { throw ResourcePackValidationError.animationFrames(count) }
        let frametime = max(1,anim.i("frametime",1))
        var frames: [Frame] = []
        if let list = anim.a("frames") {
            guard list.count <= ResourcePackLimits.maxAnimationScheduleEntries else {
                throw ResourcePackValidationError.animationSchedule(list.count)
            }
            for e in list {
                let index: Int, time: Int
                if let d = e.numberValue, let n = Int(exactly: d.rounded(.towardZero)) { index = n; time = frametime }
                else if let o = e.objectValue, o["index"] != nil { index = o.i("index"); time = max(1,o.i("time",frametime)) }
                else { continue }
                if index >= 0 && index < count { frames.append(Frame(index: index,time: time)) }
            }
        } else {
            frames = (0..<count).map { Frame(index: $0,time: frametime) }
        }
        guard let first = frames.first, frames.contains(where: { $0.index != first.index }) else { return nil }
        var cycle = 0
        for frame in frames {
            let (sum, overflow) = cycle.addingReportingOverflow(frame.time)
            guard !overflow else { return nil }
            cycle = sum
        }
        return TextureAnimation(frames: frames,interpolate: anim.b("interpolate"),frameWidth: fw,frameHeight: fh,
                                columns: columns,imageFrames: count,cycleTicks: cycle)
    }

    public func at(_ tick: Int64) -> (frame: Int, next: Int, blend: Float) {
        var t = tick % Int64(cycleTicks), i = 0
        if t < 0 { t += Int64(cycleTicks) }
        while t >= Int64(frames[i].time) { t -= Int64(frames[i].time); i += 1 }
        let frame = frames[i].index, next = frames[(i+1)%frames.count].index
        return (frame,next,interpolate && next != frame ? Float(t)/Float(frames[i].time) : 0)
    }
    /// Image coordinates: origin at the top left.
    public func origin(_ imageFrame: Int) -> (x: Int, y: Int) {
        (imageFrame%columns*frameWidth,imageFrame/columns*frameHeight)
    }
    public static func pngSize(_ png: [UInt8]) -> (width: Int, height: Int)? {
        guard png.count >= 24, Array(png[0..<8]) == [137,80,78,71,13,10,26,10],
              Array(png[12..<16]) == [73,72,68,82] else { return nil }
        let w = pngBE32(png,16), h = pngBE32(png,20)
        return w > 0 && h > 0 ? (w,h) : nil
    }
}
