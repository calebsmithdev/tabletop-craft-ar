#if os(visionOS)
import CompositorServices
import SwiftUI

public struct TableLayerConfiguration: CompositorLayerConfiguration {
    public init() {}

    public func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                                  configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
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
