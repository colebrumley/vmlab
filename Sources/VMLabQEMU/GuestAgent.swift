import Foundation
import VMLabCore

/// A client of qemu-guest-agent (QGA) on the host end of the guest's `org.qemu.guest_agent.0`
/// virtio-serial port (R-403). QGA speaks QMP's JSON but has no greeting, and the port takes one
/// client at a time, so every command opens its own connection, resynchronises with
/// `guest-sync-delimited` (which discards whatever an earlier client left unread) and closes
/// again. Commands from this process are serialised; another process's connection waits in the
/// socket's backlog until the current one closes.
public actor GuestAgent {
  public typealias Connect =
    @Sendable (_ timeout: Duration) async throws(VMLabError) ->
    any QMPTransport

  /// How long the agent has to answer the sync before it counts as absent.
  public static let defaultSyncTimeout: Duration = .seconds(5)

  public nonisolated let vm: String
  public nonisolated let socketPath: String
  public nonisolated let syncTimeout: Duration
  private let connect: Connect
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(
    vm: String, socketPath: String, syncTimeout: Duration = GuestAgent.defaultSyncTimeout,
    connect: Connect? = nil
  ) {
    self.vm = vm
    self.socketPath = socketPath
    self.syncTimeout = syncTimeout
    if let connect {
      self.connect = connect
    } else {
      self.connect = Self.unixConnector(socketPath, vm: vm)
    }
  }

  /// Runs `command` and returns its `return` value. `guest_unreachable` when the port is absent
  /// or no agent answers the sync; `engine_error` for a QGA error reply; `timeout` when the
  /// command itself is not answered within `timeout`.
  @discardableResult
  public func execute(
    _ command: String, arguments: [String: JSONValue]? = nil, timeout: Duration = .seconds(10)
  ) async throws(VMLabError) -> JSONValue {
    await acquire()
    defer { release() }
    let transport = try await connect(syncTimeout)
    let session = Session(transport: transport)
    defer { Task { await transport.close() } }
    let id = Int.random(in: 1...999_999_999)
    var sync = Data([0xFF])
    sync.append(try Self.encode("guest-sync-delimited", ["id": .number(Double(id))]))
    try await session.send(sync, vm: vm)
    while true {
      guard let message = await session.next(within: syncTimeout) else {
        throw Self.noAgent(vm: vm, socketPath: socketPath)
      }
      if message["return"] == .number(Double(id)) { break }
    }
    try await session.send(try Self.encode(command, arguments), vm: vm)
    while true {
      guard let message = await session.next(within: timeout) else {
        throw VMLabError(
          code: .timeout, message: "The guest agent of \(vm) did not answer \(command) in time.",
          hint: "The guest may be overloaded; retry, or use SSH.",
          data: [
            "vm": .string(vm), "command": .string(command),
            "timeoutSeconds": .number(QMPClient.seconds(timeout)),
          ])
      }
      if case .object(let error) = message["error"] {
        throw Self.agentError(vm: vm, command: command, error)
      }
      if let value = message["return"] { return value }
    }
  }

  // MARK: Serialising

  private func acquire() async {
    guard busy else {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }

  // MARK: Wire

  /// One connection's replies, read as JSON objects. A 0xFF delimiter (and any other byte before
  /// the first `{`) is dropped.
  final class Session: @unchecked Sendable {
    let transport: any QMPTransport
    private var iterator: AsyncStream<Data>.Iterator
    private let lock = NSLock()

    init(transport: any QMPTransport) {
      self.transport = transport
      iterator = transport.lines.makeAsyncIterator()
    }

    func send(_ line: Data, vm: String) async throws(VMLabError) {
      do { try await transport.send(line) } catch {
        throw VMLabError(
          code: .guestUnreachable, message: "The guest agent connection of \(vm) closed.",
          hint: "The guest's QEMU process may have exited; check vm_inspect.",
          data: ["vm": .string(vm), "tried": .array([.string("agent")])])
      }
    }

    /// The next JSON object, or nil when the connection ends or `within` passes (the transport
    /// is then closed, which ends the stream).
    func next(within timeout: Duration) async -> [String: JSONValue]? {
      let transport = self.transport
      let timer = Task {
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        await transport.close()
      }
      defer { timer.cancel() }
      while true {
        var it = lock.withLock { iterator }
        let line = await it.next()
        lock.withLock { iterator = it }
        guard let line else { return nil }
        guard let start = line.firstIndex(of: UInt8(ascii: "{")) else { continue }
        if let object = try? JSONDecoder().decode(
          [String: JSONValue].self, from: Data(line[start...]))
        {
          return object
        }
      }
    }
  }

  static func encode(_ command: String, _ arguments: [String: JSONValue]?) throws(VMLabError)
    -> Data
  {
    var message: [String: JSONValue] = ["execute": .string(command)]
    if let arguments { message["arguments"] = .object(arguments) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do { return try encoder.encode(message) } catch {
      throw VMLabError(
        code: .internal, message: "Cannot encode \(command)", hint: "This is a vmlab bug.",
        data: ["error": .string("\(error)")])
    }
  }

  static func unixConnector(_ path: String, vm: String) -> Connect {
    { (timeout: Duration) async throws(VMLabError) -> any QMPTransport in
      try await connectUnix(path, vm: vm, timeout: timeout)
    }
  }

  static func connectUnix(_ path: String, vm: String, timeout: Duration) async throws(VMLabError)
    -> any QMPTransport
  {
    guard FileManager.default.fileExists(atPath: path) else {
      throw VMLabError(
        code: .guestUnreachable, message: "VM \(vm) has no guest agent port.",
        hint: "The VM was started without exec_agent (or by an older vmlab); restart it.",
        data: [
          "vm": .string(vm), "tried": .array([.string("agent")]), "socket": .string(path),
          ExecFallback.connectedKey: .bool(false),
        ])
    }
    do {
      return try await UnixQMPTransport.connect(path: path, timeout: timeout)
    } catch {
      var data = error.data
      data["vm"] = .string(vm)
      data["tried"] = .array([.string("agent")])
      data[ExecFallback.connectedKey] = .bool(false)
      throw VMLabError(
        code: .guestUnreachable, message: "The guest agent socket of \(vm) refused a connection.",
        hint: "Check that the guest's QEMU process is running (vm_inspect).", data: data)
    }
  }

  static func noAgent(vm: String, socketPath: String) -> VMLabError {
    VMLabError(
      code: .guestUnreachable,
      message: "qemu-guest-agent in \(vm) did not answer.",
      hint:
        "The guest may still be booting, or the image lacks qemu-guest-agent (vmlab's cloud-init "
        + "installs it only when the guest has a network); wait and retry, or use SSH.",
      data: [
        "vm": .string(vm), "tried": .array([.string("agent")]), "socket": .string(socketPath),
        ExecFallback.connectedKey: .bool(false),
      ])
  }

  static func agentError(vm: String, command: String, _ error: [String: JSONValue]) -> VMLabError {
    let desc = error["desc"]?.stringValue ?? "unknown error"
    return VMLabError(
      code: .engineError, message: "The guest agent of \(vm) refused \(command): \(desc)",
      hint: "See data.raw for the agent's message.",
      data: [
        "engine": .string("qemu-ga"), "raw": .string(desc), "command": .string(command),
        "class": error["class"] ?? .string("GenericError"), "vm": .string(vm),
      ])
  }
}
