// Port of quest-app/Assets/Scripts/World/DayLight.cs (LightCode/LightEnv) at f7d4a0f.
// M3 reference light only; environment timelines and live light belong to M7.
public struct LightEnv: Sendable, Equatable {
    public var skyFactor, blockFactor: Float
    public var skyColor, ambient, blockTint: SIMD3<Float>
    public init(skyFactor: Float, blockFactor: Float, skyColor: SIMD3<Float>, ambient: SIMD3<Float>, blockTint: SIMD3<Float>) {
        self.skyFactor = skyFactor; self.blockFactor = blockFactor; self.skyColor = skyColor
        self.ambient = ambient; self.blockTint = blockTint
    }
    public static let noon = LightEnv(skyFactor: 1, blockFactor: 1.4, skyColor: SIMD3(repeating: 1),
                                      ambient: SIMD3(repeating: Float(10)/255), blockTint: SIMD3(1,Float(216)/255,Float(140)/255))
    public func sameAs(_ o: LightEnv) -> Bool {
        func squared(_ v: SIMD3<Float>) -> Float { v.x*v.x + v.y*v.y + v.z*v.z }
        return abs(skyFactor-o.skyFactor) < 1e-4 && abs(blockFactor-o.blockFactor) < 1e-4 &&
            squared(skyColor-o.skyColor) < 1e-8 && squared(ambient-o.ambient) < 1e-8 && squared(blockTint-o.blockTint) < 1e-8
    }
}

public enum LightCode {
    public static let openSky: UInt8 = 240, fullBright: UInt8 = 255
    public static func of(_ sky: Float, _ block: Float) -> UInt8 {
        let s = max(0,min(15,Int(sky+0.5))), b = max(0,min(15,Int(block+0.5)))
        return UInt8(s*16+b)
    }
    public static func sky(_ code: UInt8) -> Int { Int(code >> 4) }
    public static func block(_ code: UInt8) -> Int { Int(code & 15) }
    public static func bilerp(_ c: Quad4, _ fu: Float, _ fv: Float) -> UInt8 {
        let u = max(0,min(1,fu)), v = max(0,min(1,fv))
        let w0 = (1-u)*(1-v), w1 = u*(1-v), w2 = u*v, w3 = (1-u)*v
        let s = Float(sky(c.l0))*w0 + Float(sky(c.l1))*w1 + Float(sky(c.l2))*w2 + Float(sky(c.l3))*w3
        let b = Float(block(c.l0))*w0 + Float(block(c.l1))*w1 + Float(block(c.l2))*w2 + Float(block(c.l3))*w3
        return of(s,b)
    }
    public static func toSnorm(_ code: UInt8) -> Int8 { Int8(((Int(code)+15)&255)-128) }
    public static func fromSnorm(_ s: Int8) -> UInt8 {
        let w = max(-1,Float(s)/127)
        let c = Int((w*127).rounded(.toNearestOrEven))+128
        return UInt8((c-15)&255)
    }
}
