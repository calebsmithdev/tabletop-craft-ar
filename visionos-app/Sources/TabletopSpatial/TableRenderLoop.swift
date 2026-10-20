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
    private let batches: BatchRenderer
    private let eyeProbe: EyeProbe
    private var probeReader = EyeProbeReader()
    private var eyeFilter = EyeMediumFilter()
    private var eyeGeneration: UInt64?
    private var eye = SIMD3<Float>.zero
    private var eyeLook = EyeLook()
    private var eyeTime = ProcessInfo.processInfo.systemUptime
    private let animationStart = ProcessInfo.processInfo.systemUptime
    private var maxAnimationMs = 0.0
    private var monoViewports = [MTLViewport(originX: 0, originY: 0, width: 1, height: 1, znear: 0, zfar: 1)]
    private var stereoViewports = [MTLViewport(originX: 0, originY: 0, width: 1, height: 1, znear: 0, zfar: 1),
                                   MTLViewport(originX: 0, originY: 0, width: 1, height: 1, znear: 0, zfar: 1)]
    #if DEBUG
    private var debugEyePlaced = false
    private let debugEyeBlock: SIMD3<Float>?
    #endif
    private let cube: CubeRenderer?
    private var previousFrame: ContinuousClock.Instant?
    private var perfStart = ContinuousClock.now
    private var frameIntervals: [Double] = []
    private var maxUploadMs = 0.0
    private var hitchCount = 0
    private let framesInFlight = DispatchSemaphore(value: 3)
    private let logger = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "render")
    /// Placed once from the first tracked head pose (TableFrame.inFront), so it works whether
    /// the tracking origin is at the floor (device) or at the head (simulator).
    private var table: TableFrame?
    private var anchorAvailable: Bool?

    private init(handoff: LayerHandoff, control: RenderControl, scene: BatchScene, eyeProbe: EyeProbe) throws {
        layer = handoff.layer
        self.control = control; self.eyeProbe = eyeProbe
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-debugEyeBlock"), args.count > i+3,
           let x = Float(args[i+1]), let y = Float(args[i+2]), let z = Float(args[i+3]), x.isFinite, y.isFinite, z.isFinite {
            debugEyeBlock = [x,y,z]
        } else { debugEyeBlock = nil }
        #endif
        frameIntervals.reserveCapacity(2048)
        guard let queue = layer.device.makeCommandQueue() else { throw RenderError.resourceAllocation }
        self.queue = queue
        batches = try BatchRenderer(scene: scene, device: layer.device, colorFormat: layer.configuration.colorFormat,
                                    depthFormat: layer.configuration.depthFormat, viewCount: layer.properties.viewCount)
        #if DEBUG
        let showCube = ProcessInfo.processInfo.arguments.contains("-debugCube")
        #else
        let showCube = false
        #endif
        cube = showCube ? try CubeRenderer(device: layer.device, colorFormat: layer.configuration.colorFormat,
                                depthFormat: layer.configuration.depthFormat, viewCount: layer.properties.viewCount) : nil
    }

    @MainActor
    public static func start(layer: sending LayerRenderer, control: RenderControl, scene: BatchScene, eyeProbe: EyeProbe,
                             didStop: @escaping @MainActor @Sendable (String?) -> Void) {
        let handoff = LayerHandoff(layer: layer)
        Task(executorPreference: RendererTaskExecutor.shared) {
            do {
                let renderer = try TableRenderLoop(handoff: handoff, control: control, scene: scene, eyeProbe: eyeProbe)
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
        maxUploadMs = max(maxUploadMs, batches.consumeUploads(budgetMilliseconds: 3))
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        guard !control.isStopped else { return }
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty, let commands = queue.makeCommandBuffer() else { return }
        maxAnimationMs = max(maxAnimationMs, batches.animate(commands: commands, seconds: ProcessInfo.processInfo.systemUptime - animationStart))
        recordFrame()
        frame.startSubmission()
        for drawable in drawables {
            let duration = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).components
            let timestamp = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            drawable.deviceAnchor = tracking.queryDeviceAnchor(atTimestamp: timestamp)
            if table == nil, let anchor = drawable.deviceAnchor, anchor.isTracked {
                #if DEBUG
                let distance = Self.debugFloat("-debugTableDistance") ?? 0.75
                #else
                let distance: Float = 0.75
                #endif
                let placed = TableFrame.inFront(of: anchor.originFromAnchorTransform, forward: distance)
                table = placed
                logger.notice("Table placed at \(String(describing: placed.originFromTable.columns.3), privacy: .public)")
            }
            let available = drawable.deviceAnchor != nil
            if anchorAvailable != available {
                anchorAvailable = available
                let position = drawable.deviceAnchor?.originFromAnchorTransform.columns.3 ?? SIMD4<Float>(0, 0, 0, 1)
                logger.notice("Device anchor available=\(available) position=\(String(describing: position), privacy: .public)")
            }
            updateEye(drawable: drawable)
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

    private func updateEye(drawable: LayerRenderer.Drawable) {
        let generation = batches.visibleGeneration
        let incoming = generation.flatMap { eyeProbe.latest(generation: $0) }
        if eyeGeneration != generation {
            eyeFilter = EyeMediumFilter(); eyeLook = EyeLook(); eyeGeneration = generation
        }
        guard let probe = probeReader.resolve(incoming, visibleGeneration: generation) else {
            return
        }
        guard var table,
              let anchor = drawable.deviceAnchor else { return }
        let head = anchor.originFromAnchorTransform.columns.3
        #if DEBUG
        if !debugEyePlaced, let debugEyeBlock, probe.neighborhood.loaded {
            let local = (debugEyeBlock - probe.center) * probe.blockSize
            let offset = table.originFromTable * SIMD4<Float>(local,0)
            table.originFromTable.columns.3 = SIMD4<Float>(head.x-offset.x, head.y-offset.y, head.z-offset.z, 1)
            self.table = table; debugEyePlaced = true
            logger.notice("EYE debug table placement block=(\(debugEyeBlock.x, privacy: .public), \(debugEyeBlock.y, privacy: .public), \(debugEyeBlock.z, privacy: .public))")
        }
        #endif
        let p = table.tableFromOrigin * head
        eye = SIMD3(p.x,p.y,p.z)
        let block = eye / probe.blockSize + probe.center
        eyeProbe.setHead(eye)
        // An outrun is a missing sample, not an observation of air. Preserve
        // medium, fade and water vision until the actor publishes this head.
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(max(0, min(0.1, now-eyeTime))); eyeTime = now
        eyeLook = eyeFilter.update(probe.neighborhood,at: block,blockSizeM: probe.blockSize,dt: dt)
        if eyeFilter.changed { logger.notice("EYE \(self.eyeFilter.medium.rawValue, privacy: .public)") }
    }

    #if DEBUG
    private static func debugFloat(_ name: String) -> Float? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i+1), let value = Float(args[i+1]), value.isFinite else { return nil }
        return value
    }
    #endif

    private func recordFrame() {
        let now = ContinuousClock.now
        func ms(_ duration: Duration) -> Double {
            let c = duration.components
            return Double(c.seconds)*1000 + Double(c.attoseconds)/1e15
        }
        if let previousFrame {
            let interval = ms(previousFrame.duration(to: now))
            frameIntervals.append(interval)
            if interval > 50 {
                hitchCount += 1
                logger.notice("HITCH interval_ms=\(interval) upload_max_ms=\(self.maxUploadMs)")
            }
        }
        previousFrame = now
        guard ms(perfStart.duration(to: now)) >= 5000, !frameIntervals.isEmpty else { return }
        let sorted = frameIntervals.sorted()
        func percentile(_ fraction: Double) -> Double { sorted[min(sorted.count-1, Int(Double(sorted.count-1)*fraction))] }
        logger.notice("PERF frames=\(sorted.count) interval_ms p50=\(percentile(0.5)) p95=\(percentile(0.95)) p99=\(percentile(0.99)) max=\(sorted.last!) upload_max_ms=\(self.maxUploadMs) animation_max_ms=\(self.maxAnimationMs) hitches=\(self.hitchCount)")
        frameIntervals.removeAll(keepingCapacity: true)
        perfStart = now; maxUploadMs = 0; maxAnimationMs = 0; hitchCount = 0
    }

    private func encode(drawable: LayerRenderer.Drawable, commands: MTLCommandBuffer) {
        let views = StereoViews(drawable: drawable)
        let layered = layer.configuration.layout == .layered
        for passIndex in 0..<(layered ? 1 : drawable.views.count) {
            let first = layered ? 0 : passIndex
            let count = layered ? drawable.views.count : 1
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
            encoder.label = "Tabletop world batches"
            if count > 1 {
                stereoViewports[0] = drawable.views[0].textureMap.viewport
                stereoViewports[1] = drawable.views[1].textureMap.viewport
                encoder.setViewports(stereoViewports)
            } else {
                monoViewports[0] = drawable.views[first].textureMap.viewport
                encoder.setViewports(monoViewports)
            }
            if layered && count > 1 {
                var mappings = (MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: UInt32(drawable.views[0].textureMap.sliceIndex)),
                                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 1, renderTargetArrayIndexOffset: UInt32(drawable.views[1].textureMap.sliceIndex)))
                withUnsafePointer(to: &mappings) { pointer in
                    pointer.withMemoryRebound(to: MTLVertexAmplificationViewMapping.self, capacity: 2) { encoder.setVertexAmplificationCount(count, viewMappings: $0) }
                }
            }
            if let table {
                let uniforms = CubeUniforms(leftClipFromOrigin: views[first], rightClipFromOrigin: views[count > 1 ? 1 : first],
                                            originFromTable: table.originFromTable)
                batches.draw(encoder: encoder, uniforms: uniforms, eye: eye, medium: eyeFilter.medium, look: eyeLook)
                cube?.draw(encoder: encoder, uniforms: uniforms)
            }
            encoder.endEncoding()
        }
    }
}
#endif
