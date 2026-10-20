import Foundation
import Synchronization
import Testing
@testable import TabletopCore

// Synchronous sleeps model poll, injected below BSDDiscoveryTransport's actual
// Dispatch/continuation bridge. No sockets or local interface lookup are used.
private final class BlockingDiscoveryFake: BlockingDiscoverySockets, Sendable {
    struct State {
        var active = 0, maximum = 0, tcpCalls = 0, udpCalls = 0
        var ranInSwiftTask = false
    }
    let state = Mutex(State())

    private func wait(_ timeoutMs: Int, cancellation: DiscoveryCancellation, tcp: Bool) throws {
        let inTask = withUnsafeCurrentTask { $0 != nil }
        state.withLock {
            $0.active += 1
            $0.maximum = max($0.maximum, $0.active)
            if tcp { $0.tcpCalls += 1 } else { $0.udpCalls += 1 }
            $0.ranInSwiftTask = $0.ranInSwiftTask || inTask
        }
        defer { state.withLock { $0.active -= 1 } }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            try cancellation.check()
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func probeUdp(_ probe: Data, targets: [String], port: Int, timeoutMs: Int,
                  maxReplyBytes: Int, cancellation: DiscoveryCancellation) throws -> [DiscoveryDatagram] {
        try wait(timeoutMs, cancellation: cancellation, tcp: false)
        return []
    }

    func checkTcp(_ host: String, port: Int, timeoutMs: Int, cancellation: DiscoveryCancellation) throws -> Bool {
        try wait(timeoutMs, cancellation: cancellation, tcp: true)
        return host == "10.0.0.5"
    }
}

@Suite(.serialized)
struct DiscoveryConcurrencyTests {
    private func heartbeat(during operation: @Sendable () async throws -> Void) async throws {
        let finished = Mutex(false)
        let heartbeat = Task {
            // Concurrent Metal/pack tests can delay this task's initial scheduling.
            // Measure service gaps after it starts, not unrelated queueing before it.
            var previous = ContinuousClock.now
            var gaps: [Duration] = []
            while !finished.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                gaps.append(previous.duration(to: now))
                previous = now
            }
            return gaps
        }
        do {
            try await operation()
        } catch {
            finished.withLock { $0 = true }
            heartbeat.cancel()
            _ = try? await heartbeat.value
            throw error
        }
        finished.withLock { $0 = true }
        let gaps = try await heartbeat.value
        #expect(gaps.count >= 10)
        // Starvation (blocking calls on the cooperative pool) delays every tick for a whole scan wave
        // (>= 400 ms each); other suites running in parallel only add isolated scheduling jitter.
        let sorted = gaps.sorted()
        #expect(sorted[sorted.count * 9 / 10] < .milliseconds(100))
        #expect(sorted.last ?? .zero < .seconds(1))
    }

    @Test func tcpScanKeepsCooperativeHeartbeatAndBoundsWorkers() async throws {
        let fake = BlockingDiscoveryFake()
        let transport = BSDDiscoveryTransport(sockets: fake)
        let hosts = (1...120).map { "10.0.0.\($0)" }
        try await heartbeat {
            // Even callers requesting more parallelism must retain the 48 cap.
            let found = await LanDiscovery.scanTcp(hosts, 8765, 160, parallel: 96, transport: transport)
            #expect(found.count == 1 && found.first?.host == "10.0.0.5")
        }
        let state = fake.state.withLock { $0 }
        #expect(state.tcpCalls == hosts.count)
        #expect(state.maximum > 1 && state.maximum <= 48)
        #expect(state.active == 0 && !state.ranInSwiftTask)
    }

    @Test func udpProbeKeepsCooperativeHeartbeat() async throws {
        let fake = BlockingDiscoveryFake()
        let transport = BSDDiscoveryTransport(sockets: fake)
        try await heartbeat {
            let found = try await LanDiscovery.probeUdp(["10.0.0.5"], 8765, 160, transport: transport)
            #expect(found.isEmpty)
        }
        let state = fake.state.withLock { $0 }
        #expect(state.udpCalls == 1 && state.active == 0 && !state.ranInSwiftTask)
    }

    @Test func cancellingScanDrainsWorkersWithoutStartingMoreHosts() async throws {
        let fake = BlockingDiscoveryFake()
        let transport = BSDDiscoveryTransport(sockets: fake)
        let scan = Task {
            await LanDiscovery.scanTcp((1...120).map { "10.0.0.\($0)" }, 8765, 5_000, transport: transport)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while fake.state.withLock({ $0.active }) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = fake.state.withLock { $0.tcpCalls }
        let cancelled = ContinuousClock.now
        scan.cancel()
        let found = await scan.value
        #expect(started > 0)
        #expect(cancelled.duration(to: .now) < .milliseconds(100))
        #expect(found.isEmpty)
        let state = fake.state.withLock { $0 }
        #expect(state.active == 0 && state.tcpCalls <= 48)
    }

    @Test func alreadyCancelledProbeDoesNotStartBlockingWork() async {
        let fake = BlockingDiscoveryFake()
        let transport = BSDDiscoveryTransport(sockets: fake)
        let probe = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await transport.probeUdp(Data(), targets: ["10.0.0.5"], port: 8765,
                                                 timeoutMs: 5_000, maxReplyBytes: 2048)
                Issue.record("A cancelled probe completed successfully")
            } catch is CancellationError {
                // Expected: cancellation is checked before the blocking job starts.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        await probe.value
        #expect(fake.state.withLock { $0.udpCalls } == 0)
    }
}
