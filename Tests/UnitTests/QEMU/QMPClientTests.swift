import Darwin
import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

/// Replays a recorded transcript: `<` lines are sent by the "server", each `>` line is the client
/// message expected next (compared as JSON), after which the following `<` lines are sent.
actor ScriptedQMPTransport: QMPTransport {
  enum Step {
    case server(Data)
    case client([String: JSONValue])
  }

  nonisolated let lines: AsyncStream<Data>
  private let sink: AsyncStream<Data>.Continuation
  private var steps: [Step]
  private(set) var mismatches: [String] = []
  private(set) var closed = false

  init(transcript: String) {
    steps = transcript.split(separator: "\n").compactMap { line in
      let body = Data(line.dropFirst(2).utf8)
      if line.hasPrefix("< ") { return .server(body) }
      if line.hasPrefix("> ") {
        return (try? JSONDecoder().decode([String: JSONValue].self, from: body)).map(Step.client)
      }
      return nil
    }
    (lines, sink) = AsyncStream<Data>.makeStream()
    Task { await self.flush() }
  }

  private func flush() {
    while case .server(let line)? = steps.first {
      steps.removeFirst()
      sink.yield(line)
    }
    if steps.isEmpty { sink.finish() }
  }

  func send(_ line: Data) async throws {
    let got = try JSONDecoder().decode([String: JSONValue].self, from: line)
    guard case .client(let expected)? = steps.first else {
      mismatches.append("unexpected \(String(decoding: line, as: UTF8.self))")
      return
    }
    steps.removeFirst()
    if got != expected { mismatches.append("expected \(expected), got \(got)") }
    flush()
  }

  func close() async {
    closed = true
    sink.finish()
  }
}

@Suite struct QMPClientTests {
  static let transcript = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(
      path: "Fixtures/qmp/boot.jsonl")

  /// BH-5: a QMP greeting whose version numbers are not small integers trapped in `Int(_:)`;
  /// such a part reads as 0.
  @Test func qmpGreetingWithHugeVersionDoesNotTrap() async {
    await #expect(processExitsWith: .success) {
      let qemu: JSONValue = .object([
        "major": .number(1e300), "minor": .number(-1e300), "micro": .number(.infinity),
      ])
      _ = QMPClient.parseGreeting(["version": .object(["qemu": qemu])])
      _ = QMPClient.parseGreeting([
        "version": .object(["qemu": .object(["major": .number(.nan)])])
      ])
    }
    let qemu: JSONValue = .object([
      "major": .number(1e300), "minor": .number(1), "micro": .number(2),
    ])
    #expect(QMPClient.parseGreeting(["version": .object(["qemu": qemu])]).version == "0.1.2")
  }

  @Test func fixtureTranscript() async throws {
    let transport = ScriptedQMPTransport(
      transcript: try String(contentsOf: Self.transcript, encoding: .utf8))
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(5))
    #expect(await client.greeting == QMPGreeting(version: "11.1.2", capabilities: ["oob"]))

    let events = await client.events()
    try await client.execute("cont")
    #expect(try await client.queryStatus() == QMPStatus(status: "running", running: true))

    await #expect {
      try await client.execute(
        "human-monitor-command", arguments: ["command-line": .string("bogus")])
    } throws: {
      guard let error = $0 as? VMLabError else { return false }
      return error.code == .engineError && error.data["class"] == .string("GenericError")
        && error.data["raw"] == .string("unknown command: 'bogus'")
    }

    try await client.execute("system_powerdown")
    var names: [String] = []
    var shutdown: QMPEvent?
    for await event in events {
      names.append(event.name)
      if event.name == "SHUTDOWN" { shutdown = event }
    }
    #expect(names == ["RESUME", "POWERDOWN", "SHUTDOWN"])
    #expect(shutdown?.data["reason"] == .string("guest-shutdown"))
    #expect(shutdown?.timestamp == Date(timeIntervalSince1970: 1_792_334_045.251288))
    #expect(await transport.mismatches == [])
    // The transcript ended: the connection is closed and further commands fail.
    #expect(await !client.isConnected)
    await #expect {
      try await client.execute("query-status")
    } throws: { ($0 as? VMLabError)?.code == .guestUnreachable }
  }

  @Test func commandTimesOut() async throws {
    let transport = ScriptedQMPTransport(
      transcript: """
        < {"QMP": {"version": {"qemu": {"micro": 0, "minor": 0, "major": 9}}, "capabilities": []}}
        > {"execute":"qmp_capabilities","id":"vmlab-1"}
        < {"return": {}, "id": "vmlab-1"}
        > {"execute":"query-status","id":"vmlab-2"}
        > {"execute":"never","id":"vmlab-3"}
        """)
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(5))
    await #expect {
      try await client.execute("query-status", timeout: .milliseconds(100))
    } throws: {
      guard let error = $0 as? VMLabError else { return false }
      return error.code == .timeout && error.data["command"] == .string("query-status")
    }
    await client.close()
    #expect(await transport.closed)
  }

  /// A fake QMP server on a real unix socket that serves two connections in turn: the client
  /// reconnects to a running guest by path.
  @Test func reconnectsByPath() async throws {
    let path = "/tmp/vmlab-qmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    let server = try FakeQMPServer(path: path, connections: 2)
    defer { server.stop() }

    for _ in 0..<2 {
      let client = try await QMPClient.connect(socketPath: path, timeout: .seconds(5))
      #expect(await client.greeting?.version == "11.1.2")
      #expect(try await client.queryStatus().status == "running")
      await client.close()
    }
    // The server counts a connection once it sees the close.
    let deadline = ContinuousClock.now + .seconds(2)
    while server.served() < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.served() == 2)
  }

  @Test func connectToMissingSocketFails() async {
    await #expect {
      _ = try await QMPClient.connect(
        socketPath: "/tmp/vmlab-no-such-\(getpid()).sock", connectTimeout: .milliseconds(100))
    } throws: { ($0 as? VMLabError)?.code == .guestUnreachable }
  }
}

/// Answers the greeting, `qmp_capabilities` and `query-status` on each accepted connection.
final class FakeQMPServer: @unchecked Sendable {
  let path: String
  private let listener: TestListener
  private let lock = NSLock()
  private var count = 0

  init(path: String, connections: Int) throws {
    self.path = path
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: path.utf8)
      buf[path.utf8.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0, listen(fd, 1) == 0 else {
      Darwin.close(fd)
      throw POSIXError(.EADDRINUSE)
    }
    let listener = TestListener(fd)
    self.listener = listener
    let thread = Thread { [weak self] in
      for _ in 0..<connections {
        guard let client = listener.accept() else { return }
        guard let self else {
          Darwin.close(client)
          return
        }
        serve(client)
        Darwin.close(client)
        lock.withLock { count += 1 }
      }
    }
    thread.start()
  }

  func served() -> Int { lock.withLock { count } }

  func stop() {
    listener.close()
    unlink(path)
  }

  private func serve(_ client: Int32) {
    func send(_ text: String) {
      let bytes = Array((text + "\r\n").utf8)
      _ = bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
    }
    send(
      #"{"QMP": {"version": {"qemu": {"micro": 2, "minor": 1, "major": 11}}, "capabilities": []}}"#)
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress, $0.count) }
      guard n > 0 else { return }
      pending.append(contentsOf: buffer[0..<n])
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending[pending.startIndex..<newline]
        pending = Data(pending[pending.index(after: newline)...])
        guard
          let message = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line)),
          case .string(let command) = message["execute"], case .string(let id) = message["id"]
        else { continue }
        if command == "query-status" {
          send(#"{"return": {"status": "running", "running": true}, "id": "\#(id)"}"#)
        } else {
          send(#"{"return": {}, "id": "\#(id)"}"#)
        }
      }
    }
  }
}

/// A QMP server that answers every command with an empty `return` until it is muted, after which
/// it keeps the connection open and says nothing: a hung QEMU (R-1101).
actor MutableQMPTransport: QMPTransport {
  nonisolated let lines: AsyncStream<Data>
  private let sink: AsyncStream<Data>.Continuation
  private var muted = false
  private(set) var received: [String] = []
  private(set) var closed = false

  init() {
    (lines, sink) = AsyncStream<Data>.makeStream()
    sink.yield(
      Data(
        #"{"QMP": {"version": {"qemu": {"micro": 0, "minor": 1, "major": 11}}, "capabilities": []}}"#
          .utf8))
  }

  func mute() { muted = true }

  /// The peer closes the connection (QEMU exited): the stream ends, nothing was closed here.
  func hangUp() { sink.finish() }

  func send(_ line: Data) async throws {
    let message = try JSONDecoder().decode([String: JSONValue].self, from: line)
    received.append(message["execute"]?.stringValue ?? "?")
    guard !muted, case .string(let id) = message["id"] else { return }
    sink.yield(Data(#"{"return": {}, "id": "\#(id)"}"#.utf8))
  }

  func close() async {
    closed = true
    sink.finish()
  }
}

@Suite struct QMPDeadPeerTests {
  @Test func defaultWindowIsAppendixG() {
    #expect(DeadPeer.window == .seconds(5))
  }

  @Test func idleConnectionIsProbedAndStaysAlive() async throws {
    let transport = MutableQMPTransport()
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(2))
    await client.watchPeer(window: .seconds(3), interval: .milliseconds(40))
    // Polled, so a busy machine only makes it slower.
    let deadline = ContinuousClock.now + .seconds(10)
    while await transport.received.filter({ $0 == "query-status" }).count < 3,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await client.isConnected)
    #expect(await client.deadPeerReason == nil)
    #expect(await transport.received.filter { $0 == "query-status" }.count >= 3)
    await client.close()
  }

  @Test(.timeLimit(.minutes(1))) func silentPeerIsDeclaredDeadWithinTheWindow() async throws {
    let transport = MutableQMPTransport()
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(2))
    let reported = Reported()
    await client.watchPeer(window: .milliseconds(300), interval: .milliseconds(40)) { reason in
      await reported.set(reason)
    }
    await transport.mute()
    let started = ContinuousClock.now
    // A command that will never be answered, with a timeout far past any bound here, can only
    // end by the dead-peer error; it must come within a bound a busy host still meets but a
    // watchdog ignoring the 300 ms window would not.
    await #expect {
      try await client.execute("query-block", timeout: .seconds(600))
    } throws: { error in
      guard let error = error as? VMLabError else { return false }
      return DeadPeer.isDeadPeer(error) && error.data["channel"] == .string("qmp")
    }
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(5), "\(elapsed) for a 300 ms window")
    #expect(await reported.value?.contains("query-block") == true)
    #expect(await client.isConnected == false)
    #expect(await transport.closed)
    await #expect(throws: VMLabError.self) { try await client.execute("cont") }
  }

  @Test func longRunningCommandPausesDetection() async throws {
    let transport = MutableQMPTransport()
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(2))
    await client.watchPeer(window: .milliseconds(200), interval: .milliseconds(40))
    await transport.mute()
    // QEMU answers nothing while it dumps memory; that is not a dead peer.
    await #expect {
      try await client.execute("dump-guest-memory", timeout: .milliseconds(600))
    } throws: { ($0 as? VMLabError)?.code == .timeout }
    #expect(await client.deadPeerReason == nil)
    // Once it is over, the probes find the silence.
    let deadline = ContinuousClock.now + .seconds(10)
    while await client.deadPeerReason == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await client.deadPeerReason != nil)
  }
}

/// CX-15: QEMU exiting (SIGKILL, a crash) only ends the QMP stream; nothing recorded the VM's
/// exit until the next restart. A hang-up now reaches `onClosed`, once, and a close from this side
/// never does.
@Suite struct QMPHangUpTests {
  @Test func aPeerHangUpCallsOnClosedOnce() async throws {
    let transport = MutableQMPTransport()
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(2))
    let calls = Counter()
    await client.watchPeer(
      window: .seconds(5), interval: .milliseconds(40), onClosed: { await calls.bump() })
    await transport.hangUp()
    let deadline = ContinuousClock.now + .seconds(10)
    while await calls.value == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await calls.value == 1)
    #expect(await client.peerHungUp)
    #expect(await client.isConnected == false)
    // Watching a client whose peer already left reports it at once.
    await client.watchPeer(onClosed: { await calls.bump() })
    while await calls.value == 1, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await calls.value == 2)
  }

  @Test func closingFromThisSideIsNoHangUp() async throws {
    let transport = MutableQMPTransport()
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(2))
    let calls = Counter()
    await client.watchPeer(
      window: .seconds(5), interval: .milliseconds(40), onClosed: { await calls.bump() })
    await client.close()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await calls.value == 0)
    #expect(await client.peerHungUp == false)
  }
}

/// CX-24: a dump by one server stalls QEMU for every monitor; another server's watchdog took
/// that for a dead peer and marked the VM broken. The dumping client keeps a busy marker in the
/// VM directory, and a watchdog that sees a live one waits.
@Suite struct QMPBusyMarkerTests {
  static func directory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-busy-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func markers(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
      $0.hasPrefix(QMPClient.busyMarkerPrefix)
    }
  }

  @Test func aLongCommandKeepsAMarkerWhileItRuns() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let transport = MutableQMPTransport()
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(2))
    await client.watchPeer(window: .seconds(5), interval: .seconds(1), busyDirectory: dir)
    await transport.mute()
    let dump = Task { try await client.execute("dump-guest-memory", timeout: .milliseconds(400)) }
    let deadline = ContinuousClock.now + .seconds(5)
    while Self.markers(dir).isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Self.markers(dir).count == 1)
    _ = await dump.result
    #expect(Self.markers(dir).isEmpty)
    await client.close()
  }

  @Test(.timeLimit(.minutes(1))) func anotherServersMarkerHoldsOffTheWatchdog() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = dir.appending(path: "\(QMPClient.busyMarkerPrefix)\(getppid()).1")
    FileManager.default.createFile(atPath: marker.path, contents: Data())
    // A marker of a process that is gone is no excuse, and is cleaned up.
    let stale = dir.appending(path: "\(QMPClient.busyMarkerPrefix)999999.1")
    FileManager.default.createFile(atPath: stale.path, contents: Data())
    let transport = MutableQMPTransport()
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(2))
    await client.watchPeer(
      window: .milliseconds(200), interval: .milliseconds(40), busyDirectory: dir)
    await transport.mute()
    let query = Task { try await client.execute("query-block", timeout: .seconds(60)) }
    try await Task.sleep(for: .milliseconds(800))
    #expect(await client.deadPeerReason == nil)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    try FileManager.default.removeItem(at: marker)
    let deadline = ContinuousClock.now + .seconds(10)
    while await client.deadPeerReason == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await client.deadPeerReason != nil)
    _ = await query.result
  }
}

actor Counter {
  private(set) var value = 0
  func bump() { value += 1 }
}

actor Reported {
  private(set) var value: String?
  func set(_ value: String) { self.value = value }
}
