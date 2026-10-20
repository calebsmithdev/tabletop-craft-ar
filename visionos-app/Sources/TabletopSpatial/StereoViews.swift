#if os(visionOS)
import CompositorServices
import simd

struct StereoViews {
    let clipFromOrigin: [simd_float4x4]

    init(drawable: LayerRenderer.Drawable) {
        let originFromDevice = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        clipFromOrigin = drawable.views.indices.map { index in
            let viewFromOrigin = (originFromDevice * drawable.views[index].transform).inverse
            return drawable.computeProjection(convention: .rightUpBack, viewIndex: index) * viewFromOrigin
        }
    }
}
#endif
