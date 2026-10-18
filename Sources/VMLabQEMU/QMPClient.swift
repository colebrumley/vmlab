import Foundation
import VMLabCore

/// The server's greeting: `{"QMP": {"version": {...}, "capabilities": [...]}}`.
public struct QMPGreeting: Sendable, Hashable {
  /// `major.minor.micro`.
  public var version: String
  public var capabilities: [String]

  public init(version: String, capabilities: [String]) {
    self.version = version
    self.capabilities = capabilities
  }
}

/// An asynchronous QMP event (`SHUTDOWN`, `RESUME`, `GUEST_PANICKED`, ...).
public struct QMPEvent: Sendable, Hashable {
  public var name: String
  public var data: [String: JSONValue]
  public var timestamp: Date?

  public init(name: String, data: [String: JSONValue] = [:], timestamp: Date? = nil) {
    self.name = name
    self.data = data
    self.timestamp = timestamp
  }
}

/// The answer to `query-status`.
public struct QMPStatus: Sendable, Hashable {
  /// `running`, `paused`, `prelaunch`, `shutdown`, `guest-panicked`, ...
  public var status: String
  public var running: Bool

  public init(status: String, running: Bool) {
    self.status = status
    self.running = running
  }
}

/// A QMP client: the capabilities handshake, commands matched to replies by `id`, and events
/// broadcast to every `events()` stream. Reconnecting to a running guest is `connect(socketPath:)`
/// again: QEMU's QMP server takes a new client once the previous one has gone.
public actor QMPClient {
  public static let defaultTimeout: Duration = .seconds(30)

  /// Where the transport is connected; used in errors.
  public nonisolated let endpoint: String
  public private(set) var greeting: QMPGreeting?

  private let transport: any QMPTransport
  private var nextID = 0
  private var pending: [String: Pending] = [:]
  private var subscribers: [Int: AsyncStream<QMPEvent>.Continuation] = [:]
  private var nextSubscriber = 0
  private var greetingWaiters: [CheckedContinuation<QMPGreeting, any Error>] = []
  private var closed = false
  private var readerTask: Task<Void, Never>?
  private var sendChain: Task<Void, Never>?
  /// Dead-peer detection (R-1101): when the peer last spoke and what it owes.
  private let peer = PeerClock()
  private var watchdog: Task<Void, Never>?
  /// Why the peer was declared dead, once it was; the connection is closed from then on.
  public private(set) var deadPeerReason: String?

  /// Commands QEMU runs synchronously for a long time (it answers nothing meanwhile), each given
  /// its own timeout; dead-peer detection pauses while one is outstanding.
  public static let longRunningCommands: Set<String> = ["dump-guest-memory", "pmemsave", "memsave"]

  private struct Pending {
    var command: String
    var continuation: CheckedContinuation<JSONValue, any Error>
    var timer: Task<Void, Never>?
  }

  /// Connects to the QMP socket at `socketPath` and completes the handshake.
  public static func connect(
    socketPath: String, connectTimeout: Duration = .seconds(5),
    timeout: Duration = QMPClient.defaultTimeout
  ) async throws -> QMPClient {
    let transport = try await UnixQMPTransport.connect(path: socketPath, timeout: connectTimeout)
    do {
      return try await handshake(over: transport, endpoint: socketPath, timeout: timeout)
    } catch {
      await transport.close()
      throw error
    }
  }

  /// Reads the greeting from `transport`, sends `qmp_capabilities` and returns a ready client.
  public static func handshake(
    over transport: any QMPTransport, endpoint: String = "qmp",
    timeout: Duration = QMPClient.defaultTimeout
  ) async throws -> QMPClient {
    let client = QMPClient(transport: transport, endpoint: endpoint)
    await client.startReader()
    do {
      _ = try await client.waitForGreeting(timeout: timeout)
      _ = try await client.execute("qmp_capabilities", timeout: timeout)
    } catch {
      await client.close()
      throw error
    }
    return client
  }

  private init(transport: any QMPTransport, endpoint: String) {
    self.transport = transport
    self.endpoint = endpoint
  }

  /// False once the connection has closed, from either side.
  public var isConnected: Bool { !closed }

  /// Sends `command` and returns its `return` value. A QMP `error` reply throws `engine_error`;
  /// a closed connection `guest_unreachable`; no reply within `timeout`, `timeout`.
  @discardableResult
  public func execute(
    _ command: String, arguments: [String: JSONValue]? = nil,
    timeout: Duration = QMPClient.defaultTimeout
  ) async throws -> JSONValue {
    guard !closed else { throw closedError() }
    nextID += 1
    let id = "vmlab-\(nextID)"
    var message: [String: JSONValue] = ["execute": .string(command), "id": .string(id)]
    if let arguments { message["arguments"] = .object(arguments) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let line = try encoder.encode(message)
    if !Self.longRunningCommands.contains(command) { peer.awaiting(command) }
    return try await withCheckedThrowingContinuation { continuation in
      let timer = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        await self?.expire(id, after: timeout)
      }
      pending[id] = Pending(command: command, continuation: continuation, timer: timer)
      // Chained so lines leave in the order the commands were issued.
      let previous = sendChain
      sendChain = Task { [weak self, transport] in
        await previous?.value
        do { try await transport.send(line) } catch {
          await self?.fail(id, error)
        }
      }
    }
  }

  /// A new stream of every event received from now on. It finishes when the connection closes.
  public func events() -> AsyncStream<QMPEvent> {
    let (stream, continuation) = AsyncStream<QMPEvent>.makeStream(bufferingPolicy: .unbounded)
    if closed {
      continuation.finish()
      return stream
    }
    let key = nextSubscriber
    nextSubscriber += 1
    subscribers[key] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.unsubscribe(key) }
    }
    return stream
  }

  /// `query-status`.
  public func queryStatus(timeout: Duration = QMPClient.defaultTimeout) async throws -> QMPStatus {
    let reply = try await execute("query-status", timeout: timeout)
    guard case .object(let object) = reply, case .string(let status) = object["status"] else {
      throw VMLabError(
        code: .engineError, message: "QEMU answered query-status with an unexpected shape.",
        hint: "Check qemu.log in the VM directory.",
        data: ["engine": .string("qemu"), "raw": .string("\(reply)")])
    }
    var running = status == "running"
    if case .bool(let flag) = object["running"] { running = flag }
    return QMPStatus(status: status, running: running)
  }

  /// Closes the connection. Pending commands fail with `guest_unreachable`; event streams end.
  public func close() async {
    watchdog?.cancel()
    await transport.close()
    readerTask?.cancel()
    finish()
  }

  // MARK: Dead peer (R-1101)

  /// Watches the peer: every `interval` an idle connection is probed with `query-status`, and a
  /// peer that owes an answer (to a probe or any command but `longRunningCommands`) and has sent
  /// nothing for `window` is dead. Then every pending command fails with `DeadPeer.error`
  /// (`guest_unreachable`, `data.deadPeer`), the connection closes, and `onDead` gets the reason.
  public func watchPeer(
    window: Duration = DeadPeer.window, interval: Duration = DeadPeer.probeInterval,
    onDead: @escaping @Sendable (String) async -> Void = { _ in }
  ) {
    guard watchdog == nil, !closed else { return }
    peer.received()
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { return }
        guard let self, let reason = await self.checkPeer(window: window, interval: interval)
        else {
          continue
        }
        await onDead(reason)
        return
      }
    }
  }

  /// One watchdog tick: the dead-peer reason when the peer is dead (the client is then closed),
  /// else nil, probing an idle connection.
  private func checkPeer(window: Duration, interval: Duration) async -> String? {
    if closed {
      watchdog?.cancel()
      return nil
    }
    if pending.values.contains(where: { Self.longRunningCommands.contains($0.command) }) {
      return nil
    }
    if let reason = peer.overdue(window: window) {
      await declareDead(reason)
      return reason
    }
    if pending.isEmpty, peer.idle() >= interval {
      Task { [weak self] in
        _ = try? await self?.execute("query-status", timeout: window + interval)
      }
    }
    return nil
  }

  private func declareDead(_ reason: String) async {
    deadPeerReason = reason
    watchdog?.cancel()
    finish()
    await transport.close()
    readerTask?.cancel()
  }

  // MARK: Reading

  private func startReader() {
    let lines = transport.lines
    readerTask = Task { [weak self] in
      for await line in lines { await self?.handle(line) }
      await self?.finish()
    }
  }

  private func waitForGreeting(timeout: Duration) async throws -> QMPGreeting {
    if let greeting { return greeting }
    guard !closed else { throw closedError() }
    let timer = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      await self?.expireGreeting(after: timeout)
    }
    defer { timer.cancel() }
    return try await withCheckedThrowingContinuation { greetingWaiters.append($0) }
  }

  private func handle(_ line: Data) {
    peer.received()
    guard let message = try? JSONDecoder().decode([String: JSONValue].self, from: line) else {
      return
    }
    if case .object(let qmp) = message["QMP"] {
      let greeting = Self.parseGreeting(qmp)
      self.greeting = greeting
      let waiters = greetingWaiters
      greetingWaiters = []
      for waiter in waiters { waiter.resume(returning: greeting) }
      return
    }
    if case .string(let name) = message["event"] {
      var data: [String: JSONValue] = [:]
      if case .object(let object) = message["data"] { data = object }
      let event = QMPEvent(name: name, data: data, timestamp: Self.parseTimestamp(message))
      for subscriber in subscribers.values { subscriber.yield(event) }
      return
    }
    guard case .string(let id) = message["id"], let entry = pending.removeValue(forKey: id) else {
      return
    }
    entry.timer?.cancel()
    if case .object(let error) = message["error"] {
      entry.continuation.resume(throwing: Self.engineError(command: entry.command, error))
    } else {
      entry.continuation.resume(returning: message["return"] ?? .null)
    }
  }

  private func finish() {
    guard !closed else { return }
    closed = true
    let error = closedError()
    for entry in pending.values {
      entry.timer?.cancel()
      entry.continuation.resume(throwing: error)
    }
    pending = [:]
    for waiter in greetingWaiters { waiter.resume(throwing: error) }
    greetingWaiters = []
    for subscriber in subscribers.values { subscriber.finish() }
    subscribers = [:]
  }

  private func expire(_ id: String, after timeout: Duration) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    entry.continuation.resume(
      throwing: VMLabError(
        code: .timeout, message: "QEMU did not answer \(entry.command) in time.",
        hint: "The guest's QEMU process may be stuck; check qemu.log, or kill the VM.",
        data: [
          "timeoutSeconds": .number(Self.seconds(timeout)), "command": .string(entry.command),
        ]))
  }

  private func expireGreeting(after timeout: Duration) {
    let waiters = greetingWaiters
    greetingWaiters = []
    for waiter in waiters {
      waiter.resume(
        throwing: VMLabError(
          code: .timeout, message: "QEMU sent no QMP greeting in time.",
          hint:
            "Check that \(endpoint) belongs to a QEMU process; QEMU greets one QMP client at a "
            + "time, so another connection may still hold it.",
          data: ["timeoutSeconds": .number(Self.seconds(timeout))]))
    }
  }

  private func fail(_ id: String, _ error: any Error) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    entry.timer?.cancel()
    entry.continuation.resume(throwing: error)
  }

  private func unsubscribe(_ key: Int) { subscribers[key] = nil }

  private func closedError() -> VMLabError {
    if let deadPeerReason {
      return DeadPeer.error(channel: "qmp", endpoint: endpoint, reason: deadPeerReason)
    }
    return VMLabError(
      code: .guestUnreachable, message: "The QMP connection is closed.",
      hint: "The guest's QEMU process may have exited; check vm_inspect.",
      data: ["tried": .string(endpoint)])
  }

  // MARK: Parsing

  static func parseGreeting(_ qmp: [String: JSONValue]) -> QMPGreeting {
    var version = ""
    if case .object(let v) = qmp["version"], case .object(let q) = v["qemu"] {
      let parts = ["major", "minor", "micro"].map { key -> String in
        if case .number(let n) = q[key] { return String(Int(n)) }
        return "0"
      }
      version = parts.joined(separator: ".")
    }
    var capabilities: [String] = []
    if case .array(let list) = qmp["capabilities"] {
      capabilities = list.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }
    return QMPGreeting(version: version, capabilities: capabilities)
  }

  static func parseTimestamp(_ message: [String: JSONValue]) -> Date? {
    guard case .object(let ts) = message["timestamp"], case .number(let s) = ts["seconds"] else {
      return nil
    }
    var micros = 0.0
    if case .number(let us) = ts["microseconds"] { micros = us }
    return Date(timeIntervalSince1970: s + micros / 1_000_000)
  }

  static func engineError(command: String, _ error: [String: JSONValue]) -> VMLabError {
    var desc = "unknown error"
    if case .string(let d) = error["desc"] { desc = d }
    var errorClass = "GenericError"
    if case .string(let c) = error["class"] { errorClass = c }
    return VMLabError(
      code: .engineError, message: "QEMU refused \(command): \(desc)",
      hint: "See data.raw for QEMU's message.",
      data: [
        "engine": .string("qemu"), "raw": .string(desc), "class": .string(errorClass),
        "command": .string(command),
      ])
  }

  static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
