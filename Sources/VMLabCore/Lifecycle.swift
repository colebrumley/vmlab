import Foundation

/// What a lifecycle request asks of a VM. The raw values are the `vm_lifecycle` actions (Appendix
/// C); `checkpointStop` is the live checkpoint that stops the guest (`vm_checkpoint`, R-800).
public enum LifecycleAction: String, CaseIterable, Codable, Sendable {
  case start, stop, kill, pause, resume, reset, destroy
  case checkpointStop = "checkpoint_stop"
}

/// Where a legal action leaves the VM: a state, or no record at all.
public enum LifecycleTarget: Sendable, Hashable {
  case state(VMState)
  case destroyed
}

/// The lifecycle state machine (R-106). Engines ask it before acting and record the target state
/// after; an illegal pair is `wrong_state` with the current state and the legal actions.
public enum Lifecycle {
  /// The transition table. A pair that is not listed is illegal.
  public static let table: [VMState: [LifecycleAction: LifecycleTarget]] = [
    .created: [.start: .state(.running), .destroy: .destroyed],
    .running: [
      .stop: .state(.stopped), .kill: .state(.stopped), .pause: .state(.paused),
      .reset: .state(.running), .checkpointStop: .state(.suspended), .destroy: .destroyed,
    ],
    .paused: [
      .resume: .state(.running), .stop: .state(.stopped), .kill: .state(.stopped),
      .destroy: .destroyed,
    ],
    .stopped: [.start: .state(.running), .destroy: .destroyed],
    // Starting a suspended guest restores its saved state.
    .suspended: [.start: .state(.running), .destroy: .destroyed],
    // `kill` always works on a broken VM (R-1101).
    .broken: [.kill: .state(.stopped), .destroy: .destroyed],
  ]

  /// Where `action` takes a VM in `state`, or nil when it is illegal.
  public static func target(of action: LifecycleAction, from state: VMState) -> LifecycleTarget? {
    table[state]?[action]
  }

  /// The actions legal in `state`, in declaration order.
  public static func legalActions(in state: VMState) -> [LifecycleAction] {
    LifecycleAction.allCases.filter { table[state]?[$0] != nil }
  }

  /// The target of `action` from `state`; `wrong_state` when the pair is illegal.
  public static func transition(
    _ action: LifecycleAction, from state: VMState, vm: String? = nil
  ) throws(VMLabError) -> LifecycleTarget {
    guard let target = target(of: action, from: state) else {
      throw wrongState(action: action, state: state, vm: vm)
    }
    return target
  }

  /// `wrong_state` with the Appendix D `data`: `state` and `legalActions`.
  public static func wrongState(
    action: LifecycleAction, state: VMState, vm: String? = nil
  ) -> VMLabError {
    let legal = legalActions(in: state)
    let names = legal.map(\.rawValue)
    let subject = vm.map { "VM \($0)" } ?? "The VM"
    var data: [String: JSONValue] = [
      "state": .string(state.rawValue), "legalActions": .array(names.map { .string($0) }),
      "action": .string(action.rawValue),
    ]
    if let vm { data["vm"] = .string(vm) }
    return VMLabError(
      code: .wrongState,
      message: "\(subject) is \(state.rawValue); \(action.rawValue) is not allowed in that state",
      hint: legal.isEmpty
        ? "No action is allowed in this state."
        : "Allowed in state \(state.rawValue): \(names.joined(separator: ", ")).",
      data: data)
  }
}

// MARK: - Reattach

/// How `Store.reconcile` tells whether a recorded engine process is still there. Injectable so tests
/// need no real guest.
public struct LivenessProbe: Sendable {
  /// Whether a process with this pid exists.
  public var isAlive: @Sendable (Int32) -> Bool
  /// Whether the engine answers on one of its recorded sockets.
  public var isAnswering: @Sendable (VMRuntime) -> Bool

  public init(
    isAlive: @escaping @Sendable (Int32) -> Bool,
    isAnswering: @escaping @Sendable (VMRuntime) -> Bool
  ) {
    self.isAlive = isAlive
    self.isAnswering = isAnswering
  }

  /// `kill(pid, 0)`, and a connect to the control socket or the QMP socket.
  public static let system = LivenessProbe(
    isAlive: processExists,
    isAnswering: { runtime in
      ([runtime.controlSocket] + [runtime.qmpSocket].compactMap { $0 }).contains {
        canConnect(unixSocket: $0)
      }
    })

  /// `kill(pid, 0)` succeeds or fails with `EPERM`. A pid of 0 or less never names one guest.
  public static func processExists(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }

  /// Whether something accepts a connection on the unix socket at `path`.
  public static func canConnect(unixSocket path: String) -> Bool {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, bytes.count < capacity else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) == 0 }
    }
  }
}

/// One record `Store.reconcile` changed.
public struct ReconcileChange: Sendable, Equatable {
  public var id: String
  public var from: VMState
  public var to: VMState
  public var reason: String

  public init(id: String, from: VMState, to: VMState, reason: String) {
    self.id = id
    self.from = from
    self.to = to
    self.reason = reason
  }
}

extension Store {
  /// Where the VM's disk image may live (Appendix F): `vms/<id>/disk.raw` or `disk.qcow2`, and for
  /// `vz-macos` the Tart clone's `disk.img` under `TART_HOME` (default `~/.tart`) `/vms/<id>/`.
  /// `VMRecord` has no disk path yet; the engine that creates the disk follows this convention.
  public func diskCandidates(
    of record: VMRecord,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    let dir = directory(of: record.id)
    var urls = [dir.appending(path: "disk.raw"), dir.appending(path: "disk.qcow2")]
    if record.profile == .vzMacOS {
      let tart =
        environment["TART_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".tart")
      urls.append(tart.appending(path: "vms/\(record.id)/disk.img"))
    }
    return urls
  }

  /// Whether any of `diskCandidates(of:)` exists.
  public func diskExists(
    of record: VMRecord,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    diskCandidates(of: record, environment: environment).contains {
      FileManager.default.fileExists(atPath: $0.path)
    }
  }

  /// Reattach on server start: brings every record in line with its engine process. A recorded
  /// process that is alive and answers on its sockets makes the VM `running` (or keeps it `paused`).
  /// A process that is gone, or alive but not answering (its pid may have been reused), clears
  /// `runtime` and makes the VM `stopped`, or `broken` when its disk image is missing; a `suspended`
  /// VM stays `suspended`. A `running` or `paused` record with no runtime is treated as gone. Each
  /// change is written under the VM's lock and logged as a `lifecycle` event.
  @discardableResult
  public func reconcile(
    probe: LivenessProbe = .system,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws(VMLabError) -> [ReconcileChange] {
    var changes: [ReconcileChange] = []
    for record in try list().records {
      guard Self.reconciled(record, probe: probe, diskExists: { _ in true }) != nil else {
        continue
      }
      var change: ReconcileChange?
      do {
        try update(id: record.id) { (current: inout VMRecord) throws(VMLabError) in
          let disk = diskExists(of: current, environment: environment)
          guard let next = Self.reconciled(current, probe: probe, diskExists: { _ in disk }) else {
            return
          }
          change = ReconcileChange(
            id: current.id, from: current.state, to: next.record.state, reason: next.reason)
          current = next.record
        }
      } catch  where error.code == .vmNotFound {
        continue  // destroyed meanwhile
      }
      guard let change else { continue }
      changes.append(change)
      let log = EventLog(vmDirectory: directory(of: change.id))
      try? await log.append(
        .lifecycle, "reconcile: \(change.from.rawValue) -> \(change.to.rawValue): \(change.reason)",
        level: change.to == .broken ? .warning : .info)
    }
    return changes
  }

  /// The reconciled record and why, or nil when `record` needs no change.
  static func reconciled(
    _ record: VMRecord, probe: LivenessProbe, diskExists: (VMRecord) -> Bool
  ) -> (record: VMRecord, reason: String)? {
    var next = record
    let reason: String
    if let runtime = record.runtime {
      let alive = probe.isAlive(runtime.pid)
      // A VM marked broken while its engine lives (a hung peer, R-1101) stays broken until killed:
      // a hung process may still accept connections.
      if alive, record.state == .broken { return nil }
      if alive, probe.isAnswering(runtime) {
        guard record.state != .running, record.state != .paused else { return nil }
        next.state = .running
        return (next, "engine process \(runtime.pid) is alive and answering")
      }
      reason =
        alive
        ? "engine process \(runtime.pid) is alive but its sockets do not answer; treated as gone"
        : "engine process \(runtime.pid) has exited"
      next.runtime = nil
    } else {
      guard record.state.isLive else { return nil }
      reason = "the record says \(record.state.rawValue) but has no engine process"
    }
    if !diskExists(record) {
      next.state = .broken
      next.brokenReason = "the disk image is missing"
      return (next, reason + "; the disk image is missing")
    }
    if record.state != .suspended { next.state = .stopped }
    if record.state == .broken { next.state = .broken }
    if next.state != .broken { next.brokenReason = nil }
    return (next, reason)
  }
}
