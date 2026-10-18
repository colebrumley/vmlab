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
  private let fd: Int32
  private let lock = NSLock()
  private var count = 0

  init(path: String, connections: Int) throws {
    self.path = path
    unlink(path)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
    guard rc == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
    let listener = fd
    let thread = Thread { [self] in
      for _ in 0..<connections {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        serve(client)
        Darwin.close(client)
        lock.withLock { count += 1 }
      }
    }
    thread.start()
  }

  func served() -> Int { lock.withLock { count } }

  func stop() {
    Darwin.close(fd)
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

  @Test func silentPeerIsDeclaredDeadWithinTheWindow() async throws {
    let transport = MutableQMPTransport()
    let client = try await QMPClient.handshake(over: transport, timeout: .seconds(2))
    let reported = Reported()
    await client.watchPeer(window: .milliseconds(300), interval: .milliseconds(40)) { reason in
      await reported.set(reason)
    }
    await transport.mute()
    let started = ContinuousClock.now
    // A command that will never be answered fails with the dead-peer error, not its 30 s timeout.
    await #expect {
      try await client.execute("query-block")
    } throws: { error in
      guard let error = error as? VMLabError else { return false }
      return DeadPeer.isDeadPeer(error) && error.data["channel"] == .string("qmp")
    }
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(20))  // the command's own timeout is 30 s
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

actor Reported {
  private(set) var value: String?
  func set(_ value: String) { self.value = value }
}
