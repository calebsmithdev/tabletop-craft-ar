#if os(visionOS)
import ARKit
import CompositorServices
import Metal
import OSLog
import Synchronization
import TabletopCore
import TabletopRender
import simd

/// The UI can request shutdown even while the render actor never yields.
public final class RenderControl: Sendable {
    private let stopped = Mutex(false)
    public init() {}
    public func stop() { stopped.withLock { $0 = true } }
    var isStopped: Bool { stopped.withLock { $0 } }
}

private final class RendererTaskExecutor: TaskExecutor {
    static let shared = RendererTaskExecutor()
    private let queue = DispatchQueue(label: "com.tabletopcraft.render", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// The SDK's layer isn't Sendable. This is a one-way ownership transfer: the
/// MainActor callback never accesses it again; only TableRenderLoop uses it.
private struct LayerHandoff: @unchecked Sendable {
    let layer: LayerRenderer
}

public actor TableRenderLoop {
    private let layer: LayerRenderer
    private let control: RenderControl
    private let session = ARKitSession()
    private let tracking = WorldTrackingProvider()
    private let queue: MTLCommandQueue
    private let cube: CubeRenderer
    private let framesInFlight = DispatchSemaphore(value: 3)
    private let logger = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "render")
    /// Placed once from the first tracked head pose (TableFrame.inFront), so it works whether
    /// the tracking origin is at the floor (device) or at the head (simulator).
    private var table: TableFrame?
    private var anchorAvailable: Bool?

    private init(handoff: LayerHandoff, control: RenderControl) throws {
        layer = handoff.layer
        self.control = control
        guard let queue = layer.device.makeCommandQueue() else { throw RenderError.resourceAllocation }
        self.queue = queue
        cube = try CubeRenderer(device: layer.device, colorFormat: layer.configuration.colorFormat,
                                depthFormat: layer.configuration.depthFormat, viewCount: layer.properties.viewCount)
    }

    @MainActor
    public static func start(layer: sending LayerRenderer, control: RenderControl,
                             didStop: @escaping @MainActor @Sendable (String?) -> Void) {
        let handoff = LayerHandoff(layer: layer)
        Task(executorPreference: RendererTaskExecutor.shared) {
            do {
                let renderer = try TableRenderLoop(handoff: handoff, control: control)
                await renderer.run()
                await didStop(nil)
            } catch {
                await didStop(String(describing: error))
            }
        }
    }

    private func run() async {
        do { try await session.run([tracking]) }
        catch { logger.error("World tracking unavailable; identity fallback: \(error, privacy: .public)") }
        renderUntilStopped()
        session.stop()
        logger.notice("Render loop stopped; ARKit session released")
    }

    private func renderUntilStopped() {
        logger.notice("Render loop started: \(String(describing: self.layer.configuration.layout), privacy: .public)")
        var previousState: LayerRenderer.State?
        while !control.isStopped {
            let state = layer.state
            if previousState != state {
                logger.notice("Layer state: \(String(describing: state), privacy: .public)")
                previousState = state
            }
            switch state {
            case .invalidated: return
            case .paused:
                // A bounded pause lets stop() work while the compositor is suspended.
                Thread.sleep(forTimeInterval: 0.01)
            default: autoreleasepool { renderFrame() }
            }
        }
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else {
            // The compositor can temporarily exhaust frames. Avoid spinning at
            // userInteractive priority; shutdown stays bounded to one millisecond.
            Thread.sleep(forTimeInterval: 0.001)
            return
        }
        while framesInFlight.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            if control.isStopped { return }
        }
        var submitted = false
        defer { if !submitted { framesInFlight.signal() } }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        guard !control.isStopped else { return }
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty, let commands = queue.makeCommandBuffer() else { return }
        frame.startSubmission()
        for drawable in drawables {
            let duration = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).components
            let timestamp = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            drawable.deviceAnchor = tracking.queryDeviceAnchor(atTimestamp: timestamp)
            if table == nil, let anchor = drawable.deviceAnchor, anchor.isTracked {
                let placed = TableFrame.inFront(of: anchor.originFromAnchorTransform)
                table = placed
                logger.notice("Table placed at \(String(describing: placed.originFromTable.columns.3), privacy: .public)")
            }
            let available = drawable.deviceAnchor != nil
            if anchorAvailable != available {
                anchorAvailable = available
                let position = drawable.deviceAnchor?.originFromAnchorTransform.columns.3 ?? SIMD4<Float>(0, 0, 0, 1)
                logger.notice("Device anchor available=\(available) position=\(String(describing: position), privacy: .public)")
            }
            encode(drawable: drawable, commands: commands)
            drawable.encodePresent(commandBuffer: commands)
        }
        let semaphore = framesInFlight
        let logger = logger
        commands.addCompletedHandler { buffer in
            if let error = buffer.error { logger.error("GPU command failed: \(error, privacy: .public)") }
            semaphore.signal()
        }
        submitted = true
        commands.commit()
        frame.endSubmission()
    }

    private func encode(drawable: LayerRenderer.Drawable, commands: MTLCommandBuffer) {
        let views = StereoViews(drawable: drawable)
        let layered = layer.configuration.layout == .layered
        let passes = layered ? [Array(drawable.views.indices)] : drawable.views.indices.map { [$0] }
        for indices in passes {
            guard let first = indices.first else { continue }
            let textureMap = drawable.views[first].textureMap
            let textureIndex = textureMap.textureIndex
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.colorTextures[textureIndex]
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.depthAttachment.texture = drawable.depthTextures[textureIndex]
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 0 // Reverse Z: far depth.
            if layered { pass.renderTargetArrayLength = drawable.views.count }
            else {
                pass.colorAttachments[0].slice = textureMap.sliceIndex
                pass.depthAttachment.slice = textureMap.sliceIndex
            }
            let rateMaps = drawable.rasterizationRateMaps
            pass.rasterizationRateMap = rateMaps.indices.contains(textureIndex) ? rateMaps[textureIndex] : rateMaps.first
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.label = "Tabletop cube"
            encoder.setViewports(indices.map { drawable.views[$0].textureMap.viewport })
            if layered && indices.count > 1 {
                var mappings = indices.enumerated().map { slot, index in
                    MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32(slot),
                        renderTargetArrayIndexOffset: UInt32(drawable.views[index].textureMap.sliceIndex))
                }
                encoder.setVertexAmplificationCount(indices.count, viewMappings: &mappings)
            }
            if let table {
                cube.draw(encoder: encoder, uniforms: CubeUniforms(clipFromOrigin: indices.map { views.clipFromOrigin[$0] },
                           originFromTable: table.originFromTable))
            }
            encoder.endEncoding()
        }
    }
}
#endif
