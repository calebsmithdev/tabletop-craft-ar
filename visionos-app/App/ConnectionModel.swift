import Foundation
import Observation
import TabletopCore
import TabletopRender
import TabletopSpatial

@MainActor @Observable
final class ConnectionModel {
    var address = ""
    var status = SessionSnapshot()
    var found: [FoundServer] = []
    var searching = false
    var searchMessage = ""
    var prefsError = ""
    var wantsConnection = false
    @ObservationIgnored private var connectedAddress: String?
    @ObservationIgnored private var lifecycle = ConnectionLifecycle()
    @ObservationIgnored let scene = BatchScene()
    @ObservationIgnored private(set) var session: WorldSession!
    @ObservationIgnored private var prefs = AppPrefs()
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var transition: Task<Void, Never>?

    init() {
        directory = URL.applicationSupportDirectory.appendingPathComponent("TabletopCraft", isDirectory: true)
        do { prefs = try AppPrefs.load(from: directory); address = prefs.server ?? "" }
        catch { prefsError = "Could not load preferences: \(error)" }
        session = WorldSession(scene: scene)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-server"), args.indices.contains(i+1) { address = args[i+1] }
        #endif
    }

    func startObserving() {
        guard polling == nil else { return }
        let session = session!
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let latest = await session.latest()
                guard let self else { return }
                self.status = latest
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    func connect() {
        guard let normalized = ServerAddress.normalize(address) else {
            prefsError = "Enter a server host or ws://host:port/tabletop address."
            return
        }
        address = normalized; prefs.server = normalized; prefsError = ""
        do { try prefs.save(to: directory) }
        catch { prefsError = "Could not save preferences: \(error)" }
        lifecycle.cancelPause()
        wantsConnection = true
        connectedAddress = normalized
        beginConnection(normalized)
    }

    private func beginConnection(_ normalized: String) {
        let previous = transition, session = session!, workers = prefs.meshWorkers
        transition = Task {
            await previous?.value
            await session.connect(normalized, meshWorkers: workers)
        }
    }

    func disconnect(background: Bool = false) {
        if background { lifecycle.pause(wantsConnection: wantsConnection) }
        else { wantsConnection = false; lifecycle.cancelPause() }
        let previous = transition, session = session!
        transition = Task {
            await previous?.value
            await session.disconnect(background: background)
        }
    }

    func resume() {
        if lifecycle.resume(wantsConnection: wantsConnection), let connectedAddress { beginConnection(connectedAddress) }
    }
    func findServers() {
        guard !searching else { return }
        searching = true; searchMessage = "Searching this Wi-Fi…"
        Task {
            do {
                found = try await LanDiscovery.find()
                searchMessage = found.isEmpty ? "No server found. You can type its address above." : "Found \(found.count) server(s). Tap one to fill its address."
            } catch { searchMessage = "Search failed: \(error)" }
            searching = false
        }
    }
}
