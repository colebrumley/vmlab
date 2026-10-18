import Foundation
import VMLabCore

/// Opens Core `DebugTarget`s on GDB remote stubs (QEMU's `-gdb tcp:...`). `vmlab` registers one
/// with `DebugSessions.shared` at startup.
///
/// QEMU serves one client at a time and leaves a second connection unanswered in its listen
/// backlog, so a handshake that times out (or a stub that hangs up at once) is `debug_busy`, not a
/// hang. Note that QEMU stops the guest when a debugger connects.
public struct GDBDebugConnector: DebugConnector {
  /// How long the `qSupported` handshake and every later reply may take.
  public var replyTimeout: Duration

  public init(replyTimeout: Duration = .seconds(5)) {
    self.replyTimeout = replyTimeout
  }

  public func connect(to endpoint: GDBEndpoint, arch: GuestSpec.Arch) async throws(VMLabError)
    -> any DebugTarget
  {
    guard let port = UInt16(exactly: endpoint.port) else {
      throw VMLabError.invalidRequest(
        field: "endpoint", reason: "bad GDB port \(endpoint.port)", hint: "Restart the VM.")
    }
    let transport: GDBTCPTransport
    do {
      transport = try GDBTCPTransport(host: endpoint.host, port: port)
    } catch {
      throw VMLabError(
        code: .guestUnreachable,
        message: "Nothing answers on the GDB stub at \(endpoint.address)",
        hint: "Check that the VM runs (vm_inspect); a stopped VM has no stub.",
        data: [
          "endpoint": .string(endpoint.address), "tried": .string("gdb"),
          "error": .string("\(error)"),
        ])
    }
    let architecture = GDBArchitecture(guest: arch)
    let client = GDBClient(
      transport: transport,
      options: .init(replyTimeout: replyTimeout, fallbackArchitecture: architecture))
    do {
      _ = try await client.handshake()
      _ = try await client.registerMap()
    } catch let error as GDBError {
      await client.close()
      switch error {
      case .timeout, .connectionClosed:
        throw GDBDebugTarget.busy(endpoint)
      default:
        throw error.vmLabError(endpoint: endpoint)
      }
    } catch {
      await client.close()
      throw GDBError.connectionFailed("\(error)").vmLabError(endpoint: endpoint)
    }
    return GDBDebugTarget(client: client, endpoint: endpoint, architecture: architecture)
  }
}

extension GDBArchitecture {
  /// The built-in layout of a guest architecture, if there is one.
  public init?(guest: GuestSpec.Arch) {
    switch guest {
    case .arm64: self = .arm64
    case .x86_64: self = .x86_64
    case .riscv64, .other: return nil
    }
  }
}

/// A Core `DebugTarget` over one `GDBClient`, mapping `GDBError` to Appendix D codes.
public struct GDBDebugTarget: DebugTarget {
  public let client: GDBClient
  public let endpoint: GDBEndpoint
  let architecture: GDBArchitecture?

  public init(client: GDBClient, endpoint: GDBEndpoint, architecture: GDBArchitecture?) {
    self.client = client
    self.endpoint = endpoint
    self.architecture = architecture
  }

  public var isRunning: Bool {
    get async { await client.state == .running }
  }

  public var isConnected: Bool {
    get async { await !client.isClosed }
  }

  public func halt(timeout: Duration) async throws(VMLabError) -> DebugStop {
    try await lift { try await fresh(Self.stop(try await client.halt(timeout: timeout))) }
  }

  public func resume(thread: String?) async throws(VMLabError) {
    try await lift {
      if let thread {
        try await client.vCont([VContAction(.continue, thread: thread)])
      } else {
        try await client.cont()
      }
    }
  }

  public func step(thread: String?) async throws(VMLabError) {
    try await lift {
      if let thread {
        try await client.vCont([VContAction(.step, thread: thread)])
      } else {
        try await client.step()
      }
    }
  }

  public func waitForStop(timeout: Duration) async throws(VMLabError) -> DebugStop {
    try await lift { try await fresh(Self.stop(try await client.waitForStop(timeout: timeout))) }
  }

  /// The stop with the pc read now: a stop reply (or the last one, for a CPU already stopped)
  /// can predate a reset that moved the CPU back to its first instruction.
  private func fresh(_ stop: DebugStop) async throws -> DebugStop {
    guard stop.reason != .exited, let pc = try? await client.register(named: "pc").uint64 else {
      return stop
    }
    var stop = stop
    stop.pc = pc
    return stop
  }

  public func insert(_ point: DebugPoint) async throws(VMLabError) {
    let (type, kind) = try await packet(for: point)
    try await lift { try await client.insertBreakpoint(type, address: point.address, kind: kind) }
  }

  public func remove(_ point: DebugPoint) async throws(VMLabError) {
    let (type, kind) = try await packet(for: point)
    try await lift { try await client.removeBreakpoint(type, address: point.address, kind: kind) }
  }

  public func registers(thread: String?) async throws(VMLabError) -> [DebugRegister] {
    try await lift {
      if let thread { try await client.selectThread(thread) }
      return try await client.registers().map {
        DebugRegister(name: $0.register.name, value: $0.value?.hex)
      }
    }
  }

  public func readMemory(address: UInt64, length: Int, thread: String?) async throws(VMLabError)
    -> [UInt8]
  {
    try await lift {
      if let thread { try await client.selectThread(thread) }
      return try await client.readMemory(address: address, length: length)
    }
  }

  public func writeMemory(address: UInt64, bytes: [UInt8], thread: String?)
    async throws(VMLabError)
  {
    try await lift {
      if let thread { try await client.selectThread(thread) }
      try await client.writeMemory(address: address, bytes: bytes)
    }
  }

  public func close() async { await client.close() }

  // MARK: Helpers

  /// The `Z` type and `kind` field of a point: the instruction length for a breakpoint, the
  /// watched length for a watchpoint.
  private func packet(for point: DebugPoint) async throws(VMLabError) -> (BreakpointType, Int) {
    let type: BreakpointType =
      switch point.kind {
      case .software: .software
      case .hardware: .hardware
      case .watchWrite: .writeWatchpoint
      case .watchRead: .readWatchpoint
      case .watchAccess: .accessWatchpoint
      }
    if point.kind.isWatchpoint { return (type, point.size ?? 1) }
    var arch = architecture
    if let name = try? await client.registerMap().architecture {
      arch = GDBArchitecture(targetArchitecture: name) ?? arch
    }
    return (type, arch?.breakpointKind ?? 4)
  }

  static func stop(_ reason: StopReason) -> DebugStop {
    switch reason.kind {
    case .exited, .terminated:
      return DebugStop(reason: .exited, signal: Int(reason.signal), thread: reason.thread)
    case .signal:
      if let hit = reason.watchpoint {
        return DebugStop(
          reason: .watchpoint, signal: Int(reason.signal), thread: reason.thread, pc: reason.pc,
          watchAddress: hit.address)
      }
      return DebugStop(
        reason: reason.breakpoint != nil ? .breakpoint : .signal, signal: Int(reason.signal),
        thread: reason.thread, pc: reason.pc)
    }
  }

  private func lift<T: Sendable>(_ body: () async throws -> T) async throws(VMLabError) -> T {
    do {
      return try await body()
    } catch let error as GDBError {
      throw error.vmLabError(endpoint: endpoint)
    } catch let error as VMLabError {
      throw error
    } catch {
      throw GDBError.connectionFailed("\(error)").vmLabError(endpoint: endpoint)
    }
  }

  static func busy(_ endpoint: GDBEndpoint) -> VMLabError {
    VMLabError(
      code: .debugBusy,
      message: "The GDB stub at \(endpoint.address) already has a client; it serves one at a time",
      hint: "Detach the other debugger (a human's gdb or lldb, or another vmlab server), then "
        + "retry.",
      data: ["endpoint": .string(endpoint.address)])
  }
}

extension GDBError {
  /// The Appendix D error for this protocol failure on the stub at `endpoint`.
  public func vmLabError(endpoint: GDBEndpoint) -> VMLabError {
    let address = endpoint.address
    var data: [String: JSONValue] = ["endpoint": .string(address), "engine": .string("gdb")]
    switch self {
    case .connectionFailed(let detail):
      data["tried"] = .string("gdb")
      data["error"] = .string(detail)
      return VMLabError(
        code: .guestUnreachable, message: "Cannot connect to the GDB stub at \(address)",
        hint: "Check that the VM runs (vm_inspect).", data: data)
    case .connectionClosed:
      data["tried"] = .string("gdb")
      data["error"] = .string("connection closed")
      return VMLabError(
        code: .guestUnreachable, message: "The GDB stub at \(address) closed the connection",
        hint: "The engine may have stopped or restarted; call vm_debug again to reconnect.",
        data: data)
    case .timeout(let seconds):
      data["timeoutSeconds"] = .number(seconds)
      return VMLabError(
        code: .timeout, message: "The GDB stub at \(address) did not answer within \(seconds) s",
        hint: "The CPU may still run; call vm_debug halt, or wait with a longer timeoutSeconds.",
        data: data)
    case .targetRunning:
      data["state"] = .string("running")
      data["legalActions"] = .array(["halt", "wait", "info"].map { .string($0) })
      return VMLabError(
        code: .wrongState, message: "The CPU is running",
        hint: "Call vm_debug halt (or wait) first.", data: data)
    case .unknownRegister(let name):
      return VMLabError.invalidRequest(
        field: "register", reason: "no register named \(name)",
        hint: "Call vm_debug registers to list them.")
    case .stubError(let code, let message):
      data["raw"] = .string(message ?? String(format: "E%02x", code))
      return VMLabError(
        code: .engineError,
        message: "The GDB stub refused the request (\(message ?? String(format: "E%02x", code)))",
        hint: "Check the address and size: the guest may not map that memory, or the stub may "
          + "lack a free debug register.", data: data)
    case .unsupported(let packet):
      data["raw"] = .string(packet)
      return VMLabError(
        code: .engineError, message: "The GDB stub does not support \(packet)",
        hint: "Use another kind (software breakpoints work on every QEMU stub).", data: data)
    case .tooManyRetransmits, .malformedReply, .noTargetDescription, .badTargetDescription:
      data["raw"] = .string("\(self)")
      return VMLabError(
        code: .engineError, message: "The GDB stub at \(address) misbehaved: \(self)",
        hint: "Retry; if it persists, the vmlab server log has the exchange.", data: data)
    }
  }
}
