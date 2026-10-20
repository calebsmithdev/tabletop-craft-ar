import CompositorServices
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import TabletopSpatial
import TabletopCore

@main
struct TabletopCraftApp: App {
    @State private var model = TableSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("TabletopCraft", id: "launcher") {
            LauncherView(model: model)
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhase = phase
            model.logger.notice("Scene phase: \(String(describing: phase), privacy: .public)")
            if phase == .background {
                model.connection.disconnect(background: true)
                model.shouldDismiss = true
                model.control?.stop()
            } else if phase == .active {
                model.connection.resume()
            }
        }

        ImmersiveSpace(id: "table") {
            TableContent(model: model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)
    }
}

@MainActor @Observable
final class TableSession {
    enum State { case closed, opening, open, closing }
    var state = State.closed
    var scenePhase = ScenePhase.active
    var message = "Open the table before or after connecting."
    var connection = ConnectionModel()
    var control: RenderControl?
    var generation = UUID()
    var shouldDismiss = false
    let logger = Logger(subsystem: "com.tabletopcraft.ar.visionos", category: "scene")
}

struct TableContent: CompositorContent {
    var model: TableSession

    var body: some CompositorContent {
        CompositorLayer(configuration: TableLayerConfiguration()) { @MainActor layer in
            let control = model.control ?? RenderControl()
            let generation = model.generation
            TableRenderLoop.start(layer: layer, control: control, scene: model.connection.scene, eyeProbe: model.connection.session.eyeProbe) { error in
                guard model.generation == generation else { return }
                model.logger.notice("Renderer finished")
                if let error { model.message = "Renderer failed: \(error)" }
                // Dismiss through SwiftUI before enabling Open again, including
                // startup failure and a background stop racing the view update.
                model.shouldDismiss = true
                model.control = nil
            }
        }
    }
}

struct LauncherView: View {
    @Bindable var model: TableSession
    @State private var importingPack = false
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var connection = model.connection
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text("TabletopCraft").font(.largeTitle)
            Text("Live tabletop · M3").font(.title3)
            TextField("Server host or ws://host:8765/tabletop", text: $connection.address)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("serverAddress")
            Text("Allow Local Network access to connect and find servers on your Wi-Fi.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Connect") { connection.connect() }
                Button("Disconnect") { connection.disconnect() }.disabled(!connection.wantsConnection)
                Button(connection.searching ? "Searching…" : "Find servers") { connection.findServers() }
                    .disabled(connection.searching)
            }
            if !connection.searchMessage.isEmpty { Text(connection.searchMessage).font(.caption) }
            ForEach(connection.found, id: \.url) { server in
                Button(server.label) { connection.address = server.url }
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 5) {
                GridRow { Text("LINK"); Text(connection.status.link) }
                GridRow { Text("RTT"); Text(connection.status.rttMs < 0 ? "—" : String(format: "%.0f ms", connection.status.rttMs)) }
                GridRow { Text("World"); Text(connection.status.world.isEmpty ? "—" : connection.status.world) }
                GridRow { Text("Region"); Text(regionText(connection.status.dims)) }
                GridRow { Text("Snapshot"); Text(connection.status.loading) }
                GridRow { Text("PACK"); Text(connection.status.pack) }
                if !connection.status.assets.isEmpty { GridRow { Text("ASSETS"); Text(connection.status.assets) } }
                GridRow { Text("Pairing"); Text(connection.status.paired ? (connection.status.tokenSaved ? "Trusted · saved in Keychain" : "Trusted · token not saved") : "Not paired") }
            }.font(.callout.monospacedDigit())
            if !connection.status.lastError.isEmpty { Text(connection.status.lastError).foregroundStyle(.orange).font(.caption) }
            if !connection.prefsError.isEmpty { Text(connection.prefsError).foregroundStyle(.orange).font(.caption) }
            if let code = connection.status.pairCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair this headset with your server").font(.headline)
                    Text(code.spaced).font(.system(size: 42, weight: .semibold, design: .monospaced))
                    Text("Code valid for \(code.secondsLeft(Date().timeIntervalSince1970)) seconds").font(.caption)
                    Text("In the server window on your PC, type:")
                    Text("tabletop pair \(code.code)").font(.body.monospaced()).textSelection(.enabled)
                    Text(code.required ? "The world loads once the server knows this headset." : "The world works meanwhile; pairing trusts this headset.")
                        .font(.caption)
                }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
            }
            HStack {
                Button(connection.status.packLoading ? "Loading pack…" : "Import pack.zip / client jar") { importingPack = true }
                    .disabled(connection.status.packLoading)
                if connection.manualPack || connection.status.pack.contains("disabled") || connection.status.pack.contains("Render error") { Button("Use server pack") { connection.useServerPack() } }
            }
            Text("Use your own game files. A trusted server can deliver its pack automatically.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Mipmaps", isOn: $connection.mipmaps)
                    Toggle("Smooth lighting", isOn: $connection.smoothLighting)
                    Toggle("Inner leaves faces", isOn: $connection.leavesInner)
                    HStack { Text("Minimum light"); Slider(value: $connection.minLight, in: 0...1, step: 0.05); Text(connection.minLight, format: .number.precision(.fractionLength(2))) }
                    HStack { Text("Brightness"); Slider(value: $connection.brightness, in: 0...1, step: 0.05); Text(connection.brightness, format: .number.precision(.fractionLength(2))) }
                    Stepper("Mesh workers: \(connection.meshWorkers)", value: $connection.meshWorkers, in: 1...8)
                    Button("Apply settings") { connection.applySettings() }
                }.padding(.top, 8)
            }
            Text(model.message).multilineTextAlignment(.center)
            HStack {
                Button("Open table") { Task { await openTable() } }
                    .disabled(model.state != .closed)
                Button("Close table") { Task { await closeTable() } }
                    .disabled(model.state != .open)
            }
            Text("NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        }.frame(width: 640, height: 800)
        .fileImporter(isPresented: $importingPack, allowedContentTypes: [.zip, UTType(filenameExtension: "jar") ?? .data, .data], onCompletion: connection.importPack)
        .onChange(of: model.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss { Task { await closeTable() } }
        }
        .task {
            connection.startObserving()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-connectOnLaunch") { connection.connect() }
            if ProcessInfo.processInfo.arguments.contains("-findServersOnLaunch") { connection.findServers() }
            if ProcessInfo.processInfo.arguments.contains("-openTableOnLaunch") {
                try? await Task.sleep(for: .milliseconds(500))
                await openTable()
            }
            #endif
        }
    }

    private func regionText(_ dims: SIMD3<Int>) -> String {
        dims.x > 0 ? "\(dims.x) × \(dims.y) × \(dims.z)" : "—"
    }

    private func openTable() async {
        guard model.state == .closed, model.scenePhase != .background else { return }
        model.state = .opening
        model.generation = UUID()
        model.shouldDismiss = false
        model.control = RenderControl()
        model.message = "Opening table…"
        switch await openImmersiveSpace(id: "table") {
        case .opened:
            model.state = .open
            model.message = "Table open. The miniature sits 0.75 m ahead, below eye level."
            model.logger.notice("Table opened")
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-hideLauncherOnOpen") { dismissWindow(id: "launcher") }
            #endif
            if model.shouldDismiss || model.scenePhase == .background { await closeTable() }
        case .userCancelled:
            model.control?.stop()
            model.control = nil
            model.state = .closed
            model.message = "Opening cancelled."
        case .error:
            model.control?.stop()
            model.control = nil
            model.state = .closed
            model.message = "Could not open the table. Try again."
        @unknown default:
            model.control?.stop()
            model.control = nil
            model.state = .closed
            model.message = "Unknown immersive-space result."
        }
    }

    private func closeTable() async {
        guard model.state == .open else { return }
        model.state = .closing
        model.control?.stop()
        await dismissImmersiveSpace()
        model.control = nil
        model.state = .closed
        model.message = "Table closed. Ready to reopen."
        model.logger.notice("Table closed")
    }
}
