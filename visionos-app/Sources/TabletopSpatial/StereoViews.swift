#if os(visionOS)
import CompositorServices
import simd

struct StereoViews {
    let left, right: simd_float4x4
    subscript(_ index: Int) -> simd_float4x4 { index == 0 ? left : right }

    init(drawable: LayerRenderer.Drawable) {
        let originFromDevice = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        func clip(_ index: Int) -> simd_float4x4 {
            let viewFromOrigin = (originFromDevice * drawable.views[index].transform).inverse
            return drawable.computeProjection(convention: .rightUpBack, viewIndex: index) * viewFromOrigin
        }
        left = clip(0)
        right = drawable.views.count > 1 ? clip(1) : left
    }
}
#endif
