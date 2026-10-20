#if os(visionOS)
import CompositorServices
import SwiftUI

public struct TableLayerConfiguration: CompositorLayerConfiguration {
    public init() {}

    public func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                                  configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        // An eye inside the miniature can be millimetres from a fluid surface.
        // Keep reverse-Z's far plane and respect the compositor's minimum.
        var depthRange = configuration.defaultDepthRange
        depthRange.y = max(0.001, capabilities.supportedMinimumNearPlaneDistance)
        configuration.defaultDepthRange = depthRange
        configuration.isFoveationEnabled = capabilities.supportsFoveation
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = capabilities.supportsFoveation ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: options)
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        #if DEBUG
        // Exercise the per-view fallback in simulator QA.
        if ProcessInfo.processInfo.arguments.contains("-dedicatedLayout"), layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        }
        #endif
    }
}
#endif
