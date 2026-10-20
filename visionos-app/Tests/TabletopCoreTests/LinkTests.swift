// Link parity/integration tests for quest-app/Assets/Scripts/Net/LinkClient.cs at c015e32.
import Foundation
import Synchronization
import Testing
@testable import TabletopCore

private func eventually(seconds: Double = 5, _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw JsonError("timed out waiting for link") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private actor StubTransport: LinkTransport {
    var frames: [LinkFrame]
    var sent: [JSONObject] = []
    var cancelled = false
    let hangConnect: Bool
    init(_ frames: [LinkFrame] = [], hangConnect: Bool = false) { self.frames = frames; self.hangConnect = hangConnect }
    func connect(url: URL) async throws {
        while hangConnect && !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        if cancelled { throw CancellationError() }
    }
    func send(_ frame: LinkFrame) throws {
        if cancelled { throw CancellationError() }
        if case .text(let text) = frame, let m = try Json.parse(text).objectValue { sent.append(m) }
    }
    func receive() async throws -> LinkFrame {
        while frames.isEmpty && !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        if cancelled { throw CancellationError() }
        return frames.removeFirst()
    }
    func cancel() { cancelled = true }
    func append(_ frame: LinkFrame) { frames.append(frame) }
    func messages() -> [JSONObject] { sent }
}

private final class Transports: Sendable {
    private let remaining: Mutex<[StubTransport]>
    private let calls = Mutex(0)
    init(_ transports: [StubTransport]) { remaining = Mutex(transports) }
    func next() -> any LinkTransport {
        calls.withLock { $0 += 1 }
        return remaining.withLock { list in list.count > 1 ? list.removeFirst() : list[0] }
    }
    var count: Int { calls.withLock { $0 } }
}

struct LinkTests {
    @Test func queueBoundsSupersessionAndMultipartRules() {
        var q = InboundQueue()
        q.enqueue(["type": "welcome"])
        q.enqueue(["type": "chunk_snapshot", "snapshot_id": 1])
        q.enqueue(["type": "block_update", "snapshot_id": 1])
        q.enqueue(["type": "error"])
        q.enqueue(["type": "chunk_snapshot", "base": ["snapshot_id": 1], "part": 0])
        #expect(q.count == 5 && q.dropped == 0)
        q.enqueue(["type": "chunk_snapshot", "part": 1])
        #expect(q.count == 6)
        q.enqueue(["type": "chunk_snapshot", "part": 0])
        #expect(q.count == 3 && q.dropped == 4)
        #expect(q.drain().compactMap { $0.s("type") } == ["welcome", "error", "chunk_snapshot"])
        for _ in 0..<InboundQueue.max { let accepted = q.enqueue(["type": "error"]); #expect(accepted) }
        let overflow = q.enqueue(["type": "error"])
        #expect(q.full && !overflow && q.count == 4096)
    }

    @Test func trackedSendKeepAlivePairingAndFatalRetryRules() async throws {
        let first = StubTransport([.close(code: 4003, reason: "unpaired")])
        let second = StubTransport([.text(try Json.stringify(["type": "pair_code", "code": "482913"]))])
        let factory = Transports([first, second])
        var config = LinkConfiguration(); config.backoffInitialSeconds = 0.02; config.pingSeconds = 0.1; config.deadSeconds = 2
        let link = LinkClient(url: "ws://127.0.0.1:1/tabletop", deviceToken: "revoked", configuration: config, transportFactory: { factory.next() })
        await link.start()
        try await eventually { await link.pairing }
        #expect(await link.deviceTokenRejected)
        #expect(await link.deviceToken == nil)
        #expect(await link.takeRejectedDeviceToken() == "revoked")
        #expect(await link.takeRejectedDeviceToken() == nil)
        #expect(await link.deviceTokenRejected == false)
        await link.send(["type": "subscribe"])
        await link.sendPairing(["type": "subscribe"])
        await link.sendPairing(["type": "pair_request"])
        try await eventually { await second.messages().contains { $0.s("type") == "ping" } }
        let waiting = await second.messages()
        #expect(!waiting.contains { $0.s("type") == "subscribe" })
        #expect(waiting.contains { $0.s("type") == "pair_request" })
        #expect(waiting.first?.i("seq") == 0 && waiting.first?.s("device_token") == nil)
        await second.append(.text(try Json.stringify(["type": "welcome"])))
        try await eventually { await link.connected }
        let tracked = await link.sendTracked(Protocol.regionQuery())
        #expect(tracked >= 1)
        try await eventually { await second.messages().contains { $0.s("type") == "region_query" } }
        #expect(await second.messages().first { $0.s("type") == "region_query" }?.i("seq") == Int(tracked))
        await second.append(.text(try Json.stringify(["type": "error", "ref_seq": .number(Double(tracked)), "code": "unsupported"])))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await link.drain().contains { $0.i("ref_seq", -1) == Int(tracked) })
        await second.append(.close(code: 4003, reason: "denied"))
        try await eventually { await link.fatalCode == 4003 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(factory.count == 2)
        await link.stop()
    }

    @Test func silenceAndConnectDeadlinesReconnectAndStop() async throws {
        var config = LinkConfiguration(); config.deadSeconds = 0.15; config.connectTimeoutSeconds = 0.1
        config.backoffInitialSeconds = 0.01; config.backoffMaxSeconds = 0.02
        let opening = StubTransport(hangConnect: true), silent = StubTransport([.text("{\"type\":\"welcome\"}")])
        let fatal = StubTransport([.close(code: 4001, reason: "version")])
        let factory = Transports([opening, silent, fatal])
        let link = LinkClient(url: "ws://127.0.0.1:1/tabletop", configuration: config, transportFactory: { factory.next() })
        await link.start()
        try await eventually { await link.fatalCode == 4001 }
        #expect(factory.count == 3)
        #expect(await link.deadAborts == 1)
        #expect(await link.welcomes == 1)
        #expect(await link.rttMs == -1)
        await link.stop(reason: "done")
        #expect(await link.state == .stopped)
        let invalid = LinkClient(url: "https://example.invalid/tabletop")
        await invalid.start()
        #expect(await invalid.fatalCode == 1)
        #expect(await invalid.state == .fatal)
    }

    @Test func stopSendsByeAndBoundsWaitForSilentPeer() async throws {
        let transport = StubTransport([.text("{\"type\":\"welcome\"}")])
        var config = LinkConfiguration(); config.shutdownSeconds = 0.1
        let link = LinkClient(url: "ws://127.0.0.1:1/tabletop", configuration: config, transportFactory: { transport })
        await link.start()
        try await eventually { await link.connected }
        let start = ContinuousClock.now
        await link.stop(reason: "bounded")
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await transport.messages().contains { $0.s("type") == "bye" && $0.s("reason") == "bounded" })
        #expect(await link.state == .stopped)
    }

    @Test func realNWFramesHelloSnapshotPingPongByeAndFourMiBLimits() async throws {
        let server = try PythonWebSocketStub(mode: "full")
        defer { server.terminate() }
        let binarySizes = Mutex<[Int]>([])
        let link = LinkClient(url: server.url, token: "test", binary: { bytes in binarySizes.withLock { $0.append(bytes.count) } })
        await link.start()
        try await eventually(seconds: 12) {
            let count = await link.inbound.count, rtt = await link.rttMs
            return count >= 2 && rtt >= 0 && binarySizes.withLock { !$0.isEmpty }
        }
        let inbound = await link.drain()
        let snapshot = try #require(inbound.first { $0.s("type") == "chunk_snapshot" })
        #expect(snapshot.s("padding")?.utf8.count ?? 0 > 4_000_000)
        #expect(try ChunkSnapshot.from(snapshot).grid == [1, 0])
        #expect(binarySizes.withLock { $0 } == [4 << 20])
        await link.stop(reason: "test done")
        let result = try server.finish()
        #expect(result.b("hello") && result.b("server_pong") && result.b("client_ping") && result.b("bye"))
    }

    @Test func realNWSlowPartialMessageCountsAsInboundBytes() async throws {
        let server = try PythonWebSocketStub(mode: "slow")
        defer { server.terminate() }
        var config = LinkConfiguration(); config.deadSeconds = 0.35; config.pingSeconds = 0.1
        let link = LinkClient(url: server.url, configuration: config)
        await link.start()
        try await eventually(seconds: 12) { await link.inbound.count >= 2 }
        let snapshot = try #require(await link.drain().first { $0.s("type") == "chunk_snapshot" })
        #expect(try ChunkSnapshot.from(snapshot).grid == [1, 0])
        #expect(await link.deadAborts == 0)
        #expect(await link.welcomes == 1)
        await link.stop()
        _ = try server.finish()
    }

    @Test func realNWReconnectResetsHelloSequenceAfterTransientClose() async throws {
        let server = try PythonWebSocketStub(mode: "reconnect")
        defer { server.terminate() }
        var config = LinkConfiguration(); config.backoffInitialSeconds = 0.02
        let link = LinkClient(url: server.url, configuration: config)
        await link.start()
        try await eventually { await link.welcomes == 2 }
        try await eventually { await link.inbound.count >= 3 }
        #expect(await link.fatalCode == 0)
        await link.stop()
        let result = try server.finish()
        #expect(result.i("hellos") == 2 && result.b("bye"))
    }

    @Test(arguments: [4001, 4003]) func realNWApplicationCloseCodesStopRetrying(_ code: Int) async throws {
        let server = try PythonWebSocketStub(mode: String(code))
        defer { server.terminate() }
        let link = LinkClient(url: server.url)
        await link.start()
        try await eventually { await link.state == .fatal }
        #expect(await link.fatalCode == code)
        #expect(await !link.fatalReason.isEmpty)
        #expect(await link.rttMs == -1)
        await link.stop()
        _ = try server.finish()
    }
}

/// Raw RFC6455 loopback peer. Python standard library only: no downloads or system installs.
private final class PythonWebSocketStub {
    private let process = Process()
    private let output = Pipe()
    let url: String
    init(mode: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, mode]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        var line = Data()
        while let b = try output.fileHandleForReading.read(upToCount: 1), !b.isEmpty {
            if b == Data([10]) { break }; line.append(b)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            process.terminate(); throw JsonError("loopback server did not start")
        }
        url = "ws://127.0.0.1:\(port)/tabletop?test=1"
    }
    func terminate() { if process.isRunning { process.terminate() } }
    func finish() throws -> JSONObject {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw JsonError("loopback server failed: \(process.terminationStatus)") }
        return try #require(Json.parse(String(decoding: data, as: UTF8.self)).objectValue)
    }
    private static let script = #"""
import base64, hashlib, json, socket, struct, sys, time
mode=sys.argv[1]
listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(); listener.settimeout(15)
print(listener.getsockname()[1],flush=True)
c,_=listener.accept(); c.settimeout(12)
def exact(n):
    data=b''
    while len(data)<n:
        part=c.recv(n-len(data))
        if not part: raise EOFError('peer closed')
        data+=part
    return data
header=b''
while not header.endswith(b'\r\n\r\n'): header+=exact(1)
assert header.startswith(b'GET /tabletop?test=1 '),header
key=next(x.split(b':',1)[1].strip() for x in header.split(b'\r\n') if x.lower().startswith(b'sec-websocket-key:'))
accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
def frame(op,data,fin=True):
    n=len(data); h=bytes([(128 if fin else 0)|op])
    h+=bytes([n]) if n<126 else (bytes([126])+struct.pack('!H',n) if n<=65535 else bytes([127])+struct.pack('!Q',n))
    return h+data
def send(obj): c.sendall(frame(1,json.dumps(obj,separators=(',',':')).encode()))
def receive():
    a,b=exact(2); n=b&127
    if n==126: n=struct.unpack('!H',exact(2))[0]
    if n==127: n=struct.unpack('!Q',exact(8))[0]
    assert b&128,'client must mask'
    mask=exact(4); d=exact(n); d=bytes(x^mask[i%4] for i,x in enumerate(d))
    return a&15,d
op,data=receive(); hello=json.loads(data)
assert op==1 and hello['type']=='hello' and hello['seq']==0 and hello['v']==1 and hello['client']=='visionos-app',hello
assert hello['caps']==['rle_palette_v1','avatar','light_v1','biomes_v1','sections_v1','pair_v1','assets_v1']
result={'hello':True,'hellos':1,'server_pong':False,'client_ping':False,'bye':False}
if mode=='reconnect':
    send({'v':1,'type':'welcome','seq':0,'t':0,'protocol':1,'world':'world','region':{'origin':[0,0,0],'dims':[2,1,1]}})
    c.sendall(frame(8,struct.pack('!H',4005)+b'restarting')); c.close()
    c,_=listener.accept(); c.settimeout(12)
    header=b''
    while not header.endswith(b'\r\n\r\n'): header+=exact(1)
    key=next(x.split(b':',1)[1].strip() for x in header.split(b'\r\n') if x.lower().startswith(b'sec-websocket-key:'))
    accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
    c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
    op,data=receive(); hello=json.loads(data)
    assert op==1 and hello['type']=='hello' and hello['seq']==0 and hello['v']==1,hello
    result['hellos']=2
if mode in ('4001','4003'):
    c.sendall(frame(8,struct.pack('!H',int(mode))+b'fatal'))
    time.sleep(.1); c.close(); listener.close(); print(json.dumps(result)); sys.exit(0)
send({'v':1,'type':'welcome','seq':0,'t':int(time.time()*1000),'protocol':1,'world':'world','region':{'origin':[0,0,0],'dims':[2,1,1]}})
snapshot={'v':1,'type':'chunk_snapshot','seq':1,'t':0,'snapshot_id':1,'world':'world','origin':[0,0,0],'dims':[2,1,1],'order':'yzx','encoding':'rle_palette_v1','palette':['minecraft:air','minecraft:stone'],'data':[1,1,0,1],'padding':''}
base=json.dumps(snapshot,separators=(',',':')).encode()
if mode in ('full','slow'): snapshot['padding']='x'*((4<<20)-len(base))
large=json.dumps(snapshot,separators=(',',':')).encode()
if mode in ('full','slow'): assert len(large)==4<<20
if mode=='slow':
    # Both WebSocket continuations and partial TCP reads; one message takes > deadSeconds.
    c.sendall(frame(1,large[:65536],False))
    rest=large[65536:]
    for i in range(0,len(rest),65536):
        time.sleep(.03); c.sendall(frame(0,rest[i:i+65536],i+65536>=len(rest)))
else:
    c.sendall(frame(1,large))
    if mode=='full': c.sendall(frame(2,b'x'*(4<<20)))
send({'v':1,'type':'ping','seq':2,'t':123456789,'id':99})
while True:
    op,data=receive()
    if op==8: break
    m=json.loads(data); assert m['v']==1 and isinstance(m['seq'],(int,float)) and m['t']>0
    if m['type']=='pong': assert m['id']==99 and m['echo_t']==123456789; result['server_pong']=True
    elif m['type']=='ping':
        result['client_ping']=True
        send({'v':1,'type':'pong','seq':3,'t':int(time.time()*1000),'id':m['id'],'echo_t':m['t']})
    elif m['type']=='bye':
        result['bye']=True; c.sendall(frame(8,struct.pack('!H',1000)+b'done')); break
c.close(); listener.close(); print(json.dumps(result),flush=True)
"""#
}
