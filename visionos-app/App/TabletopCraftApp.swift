import CompositorServices
import OSLog
import SwiftUI
import TabletopSpatial

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
                model.shouldDismiss = true
                model.control?.stop()
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
    var message = "A lit cube, fixed in room space."
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
            TableRenderLoop.start(layer: layer, control: control) { error in
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
    var model: TableSession
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 20) {
            Text("TabletopCraft").font(.largeTitle)
            Text("Tabletop renderer · M0").font(.title3)
            Text(model.message).multilineTextAlignment(.center)
            HStack {
                Button("Open table") { Task { await openTable() } }
                    .disabled(model.state != .closed)
                Button("Close table") { Task { await closeTable() } }
                    .disabled(model.state != .open)
            }
            Text("NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 460)
        .onChange(of: model.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss { Task { await closeTable() } }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-openTableOnLaunch") {
                try? await Task.sleep(for: .milliseconds(500))
                await openTable()
            }
            #endif
        }
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
            model.message = "Table open. The cube sits 0.75 m ahead, below eye level."
            model.logger.notice("Table opened")
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
