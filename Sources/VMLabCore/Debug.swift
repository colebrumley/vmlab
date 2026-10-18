import Foundation
import Synchronization

// MARK: - Model

/// What a stop point is: a breakpoint (software patches the instruction, hardware uses a debug
/// register) or a watchpoint on writes, reads or any access of `size` bytes.
public enum DebugPointKind: String, CaseIterable, Codable, Sendable {
  case software, hardware
  case watchWrite = "watch_write"
  case watchRead = "watch_read"
  case watchAccess = "watch_access"

  public var isWatchpoint: Bool {
    switch self {
    case .software, .hardware: false
    case .watchWrite, .watchRead, .watchAccess: true
    }
  }
}

/// One breakpoint or watchpoint the debug session keeps inserted.
public struct DebugPoint: Codable, Sendable, Hashable {
  public var address: UInt64
  public var kind: DebugPointKind
  /// Bytes watched; nil for a breakpoint (the architecture's instruction length is used).
  public var size: Int?

  public init(address: UInt64, kind: DebugPointKind, size: Int? = nil) {
    self.address = address
    self.kind = kind
    self.size = kind.isWatchpoint ? size : nil
  }

  /// The same stop point: address and kind (a watchpoint is one per address and kind).
  public func matches(_ other: DebugPoint) -> Bool {
    address == other.address && kind == other.kind
  }
}

/// Why the CPU stopped, as the stub reported it.
public struct DebugStop: Sendable, Hashable {
  public enum Reason: String, Sendable, Hashable {
    /// A breakpoint the session inserted (or the stub said `swbreak`/`hwbreak`).
    case breakpoint
    /// A watchpoint triggered; `watchAddress` is the data address.
    case watchpoint
    /// A halt (the interrupt), or the debugger attaching.
    case halted
    /// A single step finished.
    case step
    /// Any other signal (a trap the session cannot attribute, a fault).
    case signal
    /// The target exited or was terminated: the stub has no more process.
    case exited
  }

  public var reason: Reason
  public var signal: Int
  public var thread: String?
  public var pc: UInt64?
  public var watchAddress: UInt64?

  public init(
    reason: Reason, signal: Int, thread: String? = nil, pc: UInt64? = nil,
    watchAddress: UInt64? = nil
  ) {
    self.reason = reason
    self.signal = signal
    self.thread = thread
    self.pc = pc
    self.watchAddress = watchAddress
  }
}

/// One register: its name in the target description and its value as `0x` hex (most significant
/// digit first), nil when the stub marked it unavailable.
public struct DebugRegister: Sendable, Hashable {
  public var name: String
  public var value: String?

  public init(name: String, value: String?) {
    self.name = name
    self.value = value
  }
}

// MARK: - Engine seam

/// A live connection to a guest's debug stub, in all-stop mode. A protocol client module (VMLabGDB)
/// conforms; Core drives it through `DebugSession` and never names the protocol. Every call throws
/// an Appendix D `VMLabError`.
public protocol DebugTarget: Sendable {
  /// Whether the CPU runs (after `resume` or `step`, until a stop is seen).
  var isRunning: Bool { get async }
  /// False once the stub closed the connection; the session then reconnects.
  var isConnected: Bool { get async }
  /// Stops the CPU (if it runs) and returns why it is stopped.
  func halt(timeout: Duration) async throws(VMLabError) -> DebugStop
  /// Resumes every CPU, or only `thread`.
  func resume(thread: String?) async throws(VMLabError)
  /// Steps one instruction of `thread` (or the current one); the stop arrives through `waitForStop`.
  func step(thread: String?) async throws(VMLabError)
  /// Blocks until the CPU stops; returns at once when it is stopped. `timeout` when it does not.
  func waitForStop(timeout: Duration) async throws(VMLabError) -> DebugStop
  func insert(_ point: DebugPoint) async throws(VMLabError)
  func remove(_ point: DebugPoint) async throws(VMLabError)
  func registers(thread: String?) async throws(VMLabError) -> [DebugRegister]
  func readMemory(address: UInt64, length: Int, thread: String?) async throws(VMLabError)
    -> [UInt8]
  func writeMemory(address: UInt64, bytes: [UInt8], thread: String?) async throws(VMLabError)
  func close() async
}

/// Opens a `DebugTarget` on a guest's stub. `debug_busy` (with `endpoint`) when the stub already
/// has another client, `guest_unreachable` when nothing listens.
public protocol DebugConnector: Sendable {
  func connect(to endpoint: GDBEndpoint, arch: GuestSpec.Arch) async throws(VMLabError)
    -> any DebugTarget
}

extension GDBEndpoint {
  /// `host:port`, what `target remote` takes.
  public var address: String { "\(host):\(port)" }
}

// MARK: - Session

/// The debug state vmlab keeps for one VM: the stub connection (owned by this process, not by any
/// one request, R-705), the stop points it keeps inserted and the symbol file a human may load.
/// Stop points and the symbol file persist in `<vm>/debug.json`, so a restarted server reconnects
/// to a stub that is still listening and inserts them again.
public actor DebugSession {
  /// What persists in `debug.json`.
  struct Saved: Codable, Sendable, Equatable {
    var points: [DebugPoint] = []
    var symbolFile: String?
  }

  public nonisolated let vm: String
  public private(set) var endpoint: GDBEndpoint
  private let arch: GuestSpec.Arch
  private let connector: any DebugConnector
  private let file: URL
  private var saved: Saved
  private var target: (any DebugTarget)?
  private var connecting: Task<any DebugTarget, any Error>?
  /// What the last resume was, so a SIGTRAP after a step reads as `step`.
  private var lastResume: Resume = .none

  private enum Resume { case none, cont, step }

  init(
    vm: String, endpoint: GDBEndpoint, arch: GuestSpec.Arch, connector: any DebugConnector,
    directory: URL
  ) {
    self.vm = vm
    self.endpoint = endpoint
    self.arch = arch
    self.connector = connector
    self.file = directory.appending(path: "debug.json")
    self.saved =
      (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
      ?? Saved()
  }

  /// Whether this process holds the stub's connection.
  public var attached: Bool { target != nil }
  public var points: [DebugPoint] { saved.points }
  public var symbolFile: String? { saved.symbolFile }

  /// Whether the CPU runs, when attached; nil otherwise.
  public func running() async -> Bool? {
    guard let target else { return nil }
    return await target.isRunning
  }

  /// Follows the VM to a new endpoint (a restarted engine picks a new port): the old connection
  /// is dropped, the stop points stay.
  func follow(_ endpoint: GDBEndpoint) async {
    guard endpoint != self.endpoint else { return }
    self.endpoint = endpoint
    await detach()
  }

  /// Records the symbol file shown by `info` (symbols are not resolved, R-701).
  public func setSymbolFile(_ path: String?) throws(VMLabError) {
    guard saved.symbolFile != path else { return }
    saved.symbolFile = path
    try persist()
  }

  /// Closes the connection, leaving the CPU as it is. Stop points stay recorded.
  public func detach() async {
    connecting?.cancel()
    connecting = nil
    if let target { await target.close() }
    target = nil
  }

  // MARK: Execution

  public func halt(timeout: Duration = .seconds(5)) async throws(VMLabError) -> DebugStop {
    try await withTarget { target throws(VMLabError) in
      self.classify(try await target.halt(timeout: timeout))
    }
  }

  public func resume(thread: String? = nil) async throws(VMLabError) {
    try await withTarget { target throws(VMLabError) in
      if await target.isRunning { return }
      try await target.resume(thread: thread)
      self.lastResume = .cont
    }
  }

  /// Steps one instruction and waits for the stop.
  public func step(thread: String? = nil, timeout: Duration = .seconds(10))
    async throws(VMLabError) -> DebugStop
  {
    try await withTarget { target throws(VMLabError) in
      if await target.isRunning { throw Self.running(self.vm, doing: "step") }
      try await target.step(thread: thread)
      self.lastResume = .step
      return self.classify(try await target.waitForStop(timeout: timeout))
    }
  }

  /// Blocks until the CPU stops (`timeout` when it does not within `timeout`).
  public func wait(timeout: Duration) async throws(VMLabError) -> DebugStop {
    try await withTarget { target throws(VMLabError) in
      self.classify(try await target.waitForStop(timeout: timeout))
    }
  }

  /// After the engine reset the guest (`vm_lifecycle reset`): inserts every point again, since a
  /// reset may clear the CPU's debug registers (QEMU under HVF does), and leaves the CPU as the
  /// reset left it: stopped at its first instruction when `halted` (`boot.haltAtStart`),
  /// otherwise running if it ran. A session that is not attached has nothing to do: it inserts
  /// the points when it next connects.
  public func afterReset(halted: Bool) async throws(VMLabError) {
    guard let target, await target.isConnected else { return }
    let wasRunning = await target.isRunning
    // A halted reset stopped the CPU through the engine; the halt takes the stub's stop reply.
    if wasRunning { _ = try await target.halt(timeout: .seconds(5)) }
    for point in saved.points {
      try? await target.remove(point)
      try await target.insert(point)
    }
    lastResume = .none
    if wasRunning && !halted { try await target.resume(thread: nil) }
  }

  // MARK: Stop points

  /// Inserts `point` and records it. On a running CPU the session halts, inserts and resumes, so
  /// the guest keeps running. Adding a point that exists already is a no-op.
  @discardableResult
  public func add(_ point: DebugPoint) async throws(VMLabError) -> [DebugPoint] {
    if saved.points.contains(where: { $0.matches(point) }) { return saved.points }
    try await withStoppedTarget { target throws(VMLabError) in
      try await target.insert(point)
    }
    saved.points.append(point)
    try persist()
    return saved.points
  }

  /// Removes the recorded point at `address` of `kind`; `invalid_request` when there is none.
  @discardableResult
  public func remove(address: UInt64, kind: DebugPointKind) async throws(VMLabError)
    -> [DebugPoint]
  {
    guard let index = saved.points.firstIndex(where: { $0.address == address && $0.kind == kind })
    else {
      throw VMLabError.invalidRequest(
        field: "address",
        reason: "no \(kind.rawValue) point at \(Self.hex(address)) on \(vm)",
        hint: "Call vm_debug breakpoints to list the points that are set.")
    }
    let point = saved.points[index]
    try await withStoppedTarget { target throws(VMLabError) in
      try await target.remove(point)
    }
    saved.points.remove(at: index)
    try persist()
    return saved.points
  }

  // MARK: State

  public func registers(thread: String? = nil) async throws(VMLabError) -> [DebugRegister] {
    try await withTarget { target throws(VMLabError) in
      if await target.isRunning { throw Self.running(self.vm, doing: "read registers") }
      return try await target.registers(thread: thread)
    }
  }

  public func readMemory(address: UInt64, length: Int, thread: String? = nil)
    async throws(VMLabError) -> [UInt8]
  {
    try await withTarget { target throws(VMLabError) in
      if await target.isRunning { throw Self.running(self.vm, doing: "read memory") }
      return try await target.readMemory(address: address, length: length, thread: thread)
    }
  }

  public func writeMemory(address: UInt64, bytes: [UInt8], thread: String? = nil)
    async throws(VMLabError)
  {
    try await withTarget { target throws(VMLabError) in
      if await target.isRunning { throw Self.running(self.vm, doing: "write memory") }
      try await target.writeMemory(address: address, bytes: bytes, thread: thread)
    }
  }

  // MARK: Internals

  /// Runs `body` on the connected target, connecting first. When the connection turns out to be
  /// gone (the stub closed it, the engine restarted), it reconnects once and runs `body` again.
  private func withTarget<T: Sendable>(
    _ body: (any DebugTarget) async throws(VMLabError) -> T
  ) async throws(VMLabError) -> T {
    let first = try await connected()
    do {
      return try await body(first)
    } catch {
      guard await !first.isConnected else { throw error }
      if let current = target, await !current.isConnected { target = nil }
      return try await body(try await connected())
    }
  }

  /// Runs `body` with the CPU stopped: a running CPU is halted for it and resumed afterwards.
  private func withStoppedTarget(
    _ body: (any DebugTarget) async throws(VMLabError) -> Void
  ) async throws(VMLabError) {
    try await withTarget { target throws(VMLabError) in
      let wasRunning = await target.isRunning
      if wasRunning { _ = try await target.halt(timeout: .seconds(5)) }
      do throws(VMLabError) {
        try await body(target)
      } catch {
        if wasRunning { try? await target.resume(thread: nil) }
        throw error
      }
      if wasRunning { try await target.resume(thread: nil) }
    }
  }

  /// The connected target; connecting (once, even for concurrent callers) and inserting every
  /// recorded stop point again when there is none.
  private func connected() async throws(VMLabError) -> any DebugTarget {
    if let target { return target }
    if let connecting {
      return try await Self.value(of: connecting)
    }
    let task = Task { [connector, endpoint, arch, points = saved.points] in
      let target = try await connector.connect(to: endpoint, arch: arch)
      // A stub may keep points from an earlier connection (a restarted server): remove before
      // inserting so none is doubled.
      for point in points {
        try? await target.remove(point)
        try await target.insert(point)
      }
      return target as any DebugTarget
    }
    connecting = task
    defer { connecting = nil }
    let target = try await Self.value(of: task)
    self.target = target
    lastResume = .none
    return target
  }

  private static func value(of task: Task<any DebugTarget, any Error>) async throws(VMLabError)
    -> any DebugTarget
  {
    do {
      return try await task.value
    } catch let error as VMLabError {
      throw error
    } catch {
      throw VMLabError(
        code: .internal, message: "Connecting the debugger failed: \(error)",
        hint: "This is a bug in vmlab; the server log has the details.",
        data: ["id": .string(UUID().uuidString.lowercased())])
    }
  }

  /// Names the stop: a watchpoint or a recorded breakpoint, a halt, a finished step, or a signal.
  private func classify(_ stop: DebugStop) -> DebugStop {
    var stop = stop
    defer { lastResume = .none }
    if stop.reason == .exited || stop.reason == .watchpoint || stop.reason == .breakpoint {
      return stop
    }
    if let pc = stop.pc, saved.points.contains(where: { !$0.kind.isWatchpoint && $0.address == pc })
    {
      stop.reason = .breakpoint
    } else if lastResume == .step && stop.signal == 5 {
      stop.reason = .step
    } else if stop.signal == 2 || (lastResume == .none && stop.signal == 5) {
      stop.reason = .halted
    } else {
      stop.reason = .signal
    }
    return stop
  }

  private func persist() throws(VMLabError) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(saved).write(to: file, options: .atomic)
    } catch {
      throw VMLabError(
        code: .internal, message: "Could not write \(file.path): \(error)",
        hint: "Check that the VM directory is writable.",
        data: ["id": .string(UUID().uuidString.lowercased())])
    }
  }

  static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

  static func running(_ vm: String, doing what: String) -> VMLabError {
    VMLabError(
      code: .wrongState, message: "The CPU of \(vm) is running; cannot \(what)",
      hint: "Call vm_debug halt (or wait for a breakpoint) first.",
      data: [
        "vm": .string(vm), "state": .string("running"),
        "legalActions": .array(
          ["info", "halt", "wait", "breakpoint_add", "breakpoint_remove", "breakpoints"].map {
            .string($0)
          }),
      ])
  }
}

// MARK: - Registry

/// The debug sessions of this process, one per VM, and the connector that opens stub connections.
/// `vmlab` registers the GDB connector at startup; a build without one refuses with `internal`.
public final class DebugSessions: Sendable {
  public static let shared = DebugSessions()

  private let state = Mutex<(connector: (any DebugConnector)?, sessions: [String: DebugSession])>(
    (nil, [:]))

  public init(connector: (any DebugConnector)? = nil) {
    state.withLock { $0.connector = connector }
  }

  public func register(_ connector: any DebugConnector) {
    state.withLock { $0.connector = connector }
  }

  /// The existing session of `vm`, if this process made one.
  public func existing(_ vm: String) -> DebugSession? {
    state.withLock { $0.sessions[vm] }
  }

  /// The session of `vm` on `endpoint`, made on first use (it loads `debug.json` from `directory`).
  /// A session whose VM moved to another endpoint follows it.
  public func session(
    vm: String, endpoint: GDBEndpoint, arch: GuestSpec.Arch, directory: URL
  ) async throws(VMLabError) -> DebugSession {
    let found = try state.withLock { s throws(VMLabError) -> (DebugSession, Bool) in
      if let session = s.sessions[vm] { return (session, false) }
      guard let connector = s.connector else {
        throw VMLabError(
          code: .internal, message: "This vmlab build has no debugger connector",
          hint: "Run the vmlab executable, which registers the GDB client at startup.",
          data: ["id": .string(UUID().uuidString.lowercased())])
      }
      let session = DebugSession(
        vm: vm, endpoint: endpoint, arch: arch, connector: connector, directory: directory)
      s.sessions[vm] = session
      return (session, true)
    }
    if !found.1 { await found.0.follow(endpoint) }
    return found.0
  }

  /// Forgets `vm`'s session, closing its connection (the VM was destroyed or stopped).
  public func drop(_ vm: String) async {
    let session = state.withLock { $0.sessions.removeValue(forKey: vm) }
    await session?.detach()
  }
}
