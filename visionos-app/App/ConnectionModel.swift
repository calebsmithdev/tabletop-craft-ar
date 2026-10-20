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
    var manualPack = false
    var mipmaps = true
    var smoothLighting = true
    var minLight: Double = 0.2
    var brightness: Double = 1
    var leavesInner = true
    var meshWorkers = 3
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
        manualPack = prefs.manualPack
        mipmaps = prefs.mipmaps; smoothLighting = prefs.smoothLighting
        minLight = Double(prefs.minLight); brightness = Double(prefs.brightness)
        leavesInner = prefs.leavesInner; meshWorkers = prefs.meshWorkers
        session = WorldSession(scene: scene, assetDirectory: directory)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-server"), args.indices.contains(i+1) { address = args[i+1] }
        if args.contains("-mipmapsOff") { mipmaps = false; prefs.mipmaps = false }
        if args.contains("-importPack") { manualPack = true; prefs.manualPack = true }
        #endif
    }

    func applySettings() {
        prefs.manualPack = manualPack
        prefs.mipmaps = mipmaps; prefs.smoothLighting = smoothLighting
        prefs.minLight = Float(minLight); prefs.brightness = Float(brightness)
        prefs.leavesInner = leavesInner; prefs.meshWorkers = meshWorkers
        do { try prefs.save(to: directory); prefsError = "" }
        catch { prefsError = "Could not save preferences: \(error)" }
        let prefs = prefs, session = session!
        Task { await session.configure(prefs) }
    }

    func importPack(_ result: Result<URL, any Error>) {
        switch result {
        case .failure(let error): prefsError = "Import failed: \(error)"
        case .success(let url):
            let session = session!
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if await session.importPack(url) {
                    manualPack = true; prefs.manualPack = true
                    do { try prefs.save(to: directory) }
                    catch { prefsError = "Could not save preferences: \(error)" }
                }
            }
        }
    }

    func useServerPack() {
        manualPack = false; applySettings()
        let session = session!
        Task { await session.useServerPack() }
    }

    func startObserving() {
        guard polling == nil else { return }
        let session = session!, prefs = prefs
        polling = Task { [weak self] in
            await session.configure(prefs)
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-importPack"), args.indices.contains(i+1) {
                await session.importPack(URL(fileURLWithPath: args[i+1]))
            }
            let reloadDelay: Double? = args.firstIndex(of: "-reloadPackAfter").flatMap { args.indices.contains($0+1) ? Double(args[$0+1]) : nil }
            let reloadAt = reloadDelay.map { ProcessInfo.processInfo.systemUptime + max(1, $0) }
            var reloaded = false
            #endif
            while !Task.isCancelled {
                #if DEBUG
                if !reloaded, let reloadAt, ProcessInfo.processInfo.systemUptime >= reloadAt {
                    reloaded = true; await session.reloadPack()
                }
                #endif
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
        let previous = transition, session = session!, prefs = prefs
        transition = Task {
            await previous?.value
            await session.configure(prefs)
            await session.connect(normalized, meshWorkers: prefs.meshWorkers)
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
