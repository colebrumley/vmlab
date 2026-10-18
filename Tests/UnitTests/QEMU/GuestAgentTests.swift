import Foundation
import Synchronization
import Testing
import VMLabCore

@testable import VMLabQEMU

/// A qemu-guest-agent stand-in: every connection is a fresh transport whose replies come from
/// `respond` (nil stays silent). It records each command it was sent and can leave a stale reply
/// on a connection, as a real port does after an earlier client left one unread.
final class FakeAgent: Sendable {
  typealias Respond = @Sendable (String, [String: JSONValue]) -> JSONValue?

  let respond: Respond
  let stale: Bool
  private let log = Mutex<[(String, [String: JSONValue])]>([])
  private let connections = Mutex(0)

  init(stale: Bool = false, respond: @escaping Respond) {
    self.stale = stale
    self.respond = respond
  }

  var commands: [String] { log.withLock { $0.map(\.0) } }
  func arguments(of command: String) -> [[String: JSONValue]] {
    log.withLock { $0.filter { $0.0 == command }.map(\.1) }
  }
  var connectionCount: Int { connections.withLock { $0 } }

  func agent(syncTimeout: Duration = .milliseconds(200)) -> GuestAgent {
    GuestAgent(vm: "vm-t", socketPath: "/tmp/qga.sock", syncTimeout: syncTimeout) {
      [self] _ throws(VMLabError) in
      connections.withLock { $0 += 1 }
      return Transport(agent: self)
    }
  }

  fileprivate func record(_ command: String, _ arguments: [String: JSONValue]) {
    log.withLock { $0.append((command, arguments)) }
  }

  final class Transport: QMPTransport {
    let lines: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private let agent: FakeAgent

    init(agent: FakeAgent) {
      self.agent = agent
      (lines, sink) = AsyncStream<Data>.makeStream()
      if agent.stale { sink.yield(Data(#"{"return": {"pid": 999}}"#.utf8)) }
    }

    func send(_ line: Data) async throws {
      var body = line
      if body.first == 0xFF { body = body.dropFirst() }
      let message = try JSONDecoder().decode([String: JSONValue].self, from: Data(body))
      let command = message["execute"]?.stringValue ?? ""
      let arguments = message["arguments"]?.objectValue ?? [:]
      if command == "guest-sync-delimited" {
        guard agent.respond(command, arguments) != nil else { return }
        let id = arguments["id"] ?? .null
        sink.yield(Data([0xFF]) + (try JSONEncoder().encode(["return": id])))
        return
      }
      agent.record(command, arguments)
      guard let reply = agent.respond(command, arguments) else { return }
      sink.yield(try JSONEncoder().encode(reply))
    }

    func close() async { sink.finish() }
  }
}

@Suite struct GuestAgentTests {
  @Test func syncsThenReturnsTheReply() async throws {
    let fake = FakeAgent(stale: true) { command, _ in
      command == "guest-info" ? .object(["return": .object(["version": .string("10.0")])]) : .null
    }
    let reply = try await fake.agent().execute("guest-info")
    #expect(reply["version"] == .string("10.0"))
    #expect(fake.commands == ["guest-info"])
  }

  @Test func eachCommandHasItsOwnConnection() async throws {
    let fake = FakeAgent { _, _ in .object(["return": .object([:])]) }
    let agent = fake.agent()
    try await agent.execute("guest-ping")
    try await agent.execute("guest-ping")
    #expect(fake.connectionCount == 2)
  }

  @Test func anAgentErrorIsEngineError() async throws {
    let fake = FakeAgent { _, _ in
      .object(["error": .object(["class": .string("GenericError"), "desc": .string("no")])])
    }
    let error = await #expect(throws: VMLabError.self) {
      try await fake.agent().execute("guest-exec")
    }
    #expect(error?.code == .engineError)
    #expect(error?.data["engine"] == .string("qemu-ga"))
    #expect(error?.data["raw"] == .string("no"))
  }

  /// No agent in the guest: the sync goes unanswered, which is `guest_unreachable` that never
  /// connected, so `via: auto` may try elsewhere.
  @Test func silenceIsGuestUnreachable() async throws {
    let fake = FakeAgent { _, _ in nil }
    let error = await #expect(throws: VMLabError.self) {
      try await fake.agent().execute("guest-ping")
    }
    #expect(error?.code == .guestUnreachable)
    #expect(error?.data[ExecFallback.connectedKey] == .bool(false))
    #expect(error?.data["tried"] == .array([.string("agent")]))
  }

  @Test func aMissingSocketIsGuestUnreachable() async throws {
    let agent = GuestAgent(vm: "vm-t", socketPath: "/tmp/vmlab-no-such-\(UUID()).sock")
    let error = await #expect(throws: VMLabError.self) { try await agent.execute("guest-ping") }
    #expect(error?.code == .guestUnreachable)
    #expect(error?.data[ExecFallback.connectedKey] == .bool(false))
  }
}

/// `GuestAgentExecChannel` against the fake agent: the `guest-exec` arguments, polling to the
/// exit, base64 output, and the kill at the deadline.
@Suite struct GuestAgentExecChannelTests {
  static func channel(_ fake: FakeAgent) throws -> (GuestAgentExecChannel, URL) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-qga-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var channel = GuestAgentExecChannel(agent: fake.agent(), vmDirectory: dir)
    channel.firstPoll = .milliseconds(5)
    channel.maxPoll = .milliseconds(20)
    channel.reapTimeout = .seconds(2)
    return (channel, dir)
  }

  static func b64(_ text: String) -> JSONValue { .string(Data(text.utf8).base64EncodedString()) }

  @Test func runsAndCollectsTheExit() async throws {
    let polls = Mutex(0)
    let fake = FakeAgent { command, _ in
      switch command {
      case "guest-exec": return .object(["return": .object(["pid": .number(77)])])
      case "guest-exec-status":
        let n = polls.withLock {
          $0 += 1
          return $0
        }
        guard n >= 3 else { return .object(["return": .object(["exited": .bool(false)])]) }
        return .object([
          "return": .object([
            "exited": .bool(true), "exitcode": .number(0), "out-data": Self.b64("uid=0(root)\n"),
            "err-data": Self.b64("warn\n"),
          ])
        ])
      default: return .object(["return": .object([:])])
      }
    }
    let (channel, dir) = try Self.channel(fake)
    defer { try? FileManager.default.removeItem(at: dir) }
    let result = try await channel.run(
      ExecRequest(command: "id", stdin: Data("in".utf8), cwd: "/root", user: "debian"))
    #expect(result.exitCode == 0)
    #expect(result.stdout == "uid=0(root)\n")
    #expect(result.stderr == "warn\n")
    #expect(!result.truncated)

    let exec = try #require(fake.arguments(of: "guest-exec").first)
    #expect(exec["path"] == .string("/bin/sh"))
    #expect(exec["capture-output"] == .bool(true))
    #expect(exec["input-data"] == Self.b64("in"))
    let script = try #require(exec["arg"]?.arrayValue?.last?.stringValue)
    #expect(script.hasPrefix("sudo -n -u 'debian' -H -- /bin/sh -c "))
    #expect(script.contains("cd ") && script.contains("/root"))
    #expect(fake.arguments(of: "guest-exec-status").allSatisfy { $0["pid"] == .number(77) })
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "exec").path)
        .isEmpty)
  }

  @Test func aSignalIs128PlusIt() {
    #expect(GuestAgentExecChannel.exitCode(["exited": .bool(true), "signal": .number(9)]) == 137)
    #expect(GuestAgentExecChannel.exitCode(["exited": .bool(true), "exitcode": .number(3)]) == 3)
  }

  /// BH-2: qemu-guest-agent runs in the guest; an `exitcode` or `signal` outside Int32 (or not a
  /// number at all) trapped the server. It is -1 now.
  @Test func guestAgentExitCodeOutOfRangeDoesNotTrap() async {
    await #expect(processExitsWith: .success) {
      _ = GuestAgentExecChannel.exitCode(["exitcode": .number(1e10)])
      _ = GuestAgentExecChannel.exitCode(["signal": .number(Double(Int32.max))])
      _ = GuestAgentExecChannel.exitCode(["exitcode": .number(.nan)])
      _ = GuestAgentExecChannel.exitCode(["signal": .number(-.infinity)])
    }
    #expect(GuestAgentExecChannel.exitCode(["exitcode": .number(1e10)]) == -1)
    #expect(GuestAgentExecChannel.exitCode(["signal": .number(Double(Int32.max))]) == -1)
    #expect(GuestAgentExecChannel.exitCode(["signal": .number(-3)]) == -1)
  }

  /// At the deadline the job's group is killed with a second `guest-exec`, and the refusal is
  /// `timeout` with the output the agent reports once the command has gone.
  @Test func timeoutKillsTheGroup() async throws {
    let killed = Mutex(false)
    let fake = FakeAgent { command, arguments in
      switch command {
      case "guest-exec":
        let script = arguments["arg"]?.arrayValue?.last?.stringValue ?? ""
        if script.contains("kill -TERM") { killed.withLock { $0 = true } }
        return .object(["return": .object(["pid": .number(killed.withLock { $0 } ? 78 : 77)])])
      case "guest-exec-status":
        guard killed.withLock({ $0 }) else {
          return .object(["return": .object(["exited": .bool(false)])])
        }
        return .object([
          "return": .object([
            "exited": .bool(true), "exitcode": .number(143), "out-data": Self.b64("started\n"),
          ])
        ])
      default: return .object(["return": .object([:])])
      }
    }
    let (channel, dir) = try Self.channel(fake)
    defer { try? FileManager.default.removeItem(at: dir) }
    let started = ContinuousClock.now
    let error = await #expect(throws: VMLabError.self) {
      try await channel.run(ExecRequest(command: "sleep 300", timeout: .milliseconds(300)))
    }
    // Generous: it must not wait for the command, and a loaded host can take seconds.
    #expect(ContinuousClock.now - started < .seconds(30))
    #expect(error?.code == .timeout)
    #expect(error?.data["stdout"] == .string("started\n"))
    #expect(killed.withLock { $0 })
  }

  @Test func bigOutputIsCutWithALog() async throws {
    let big = String(repeating: "a", count: 200 * 1024)
    let fake = FakeAgent { command, _ in
      switch command {
      case "guest-exec": return .object(["return": .object(["pid": .number(1)])])
      default:
        return .object([
          "return": .object([
            "exited": .bool(true), "exitcode": .number(0), "out-data": Self.b64(big),
          ])
        ])
      }
    }
    let (channel, dir) = try Self.channel(fake)
    defer { try? FileManager.default.removeItem(at: dir) }
    let result = try await channel.run(ExecRequest(command: "big"))
    #expect(result.truncated)
    let log = try #require(result.logPath)
    #expect(try Data(contentsOf: URL(filePath: log)).count == 200 * 1024)
  }
}
