import Foundation
import Logging

/// Drives VMs through their lifecycle: checks each action against `Lifecycle`, calls the VM's
/// `Backend`, records the target state in the `Store` and logs a `lifecycle` event. Actions on one
/// VM are serialized within this process; the record is re-checked under its lock before the new
/// state is written, so a change made meanwhile by another process is refused with `wrong_state`
/// rather than overwritten.
public actor VMManager {
  public nonisolated let store: Store
  public nonisolated let backends: BackendRegistry
  /// Takes the guest manifests `vm_checkpoint create manifest: true` asks for (R-801,
  /// `CheckpointManifests`; `ToolContext` passes one); without one the checkpoint is taken
  /// without a manifest and a warning says so.
  public nonisolated let manifests: (any GuestManifestTaker)?

  /// How a start waits for the guest to answer SSH (R-400).
  public nonisolated let readiness: any GuestReadiness
  /// Runs `ssh-keygen` for a new VM's key pair.
  public nonisolated let keygen: any CommandRunning
  /// The segments VMs join (R-901) and their switch processes.
  public nonisolated let segments: SegmentStore
  /// Writes the segment's names into members' `/etc/hosts` (R-902).
  public nonisolated let naming: any SegmentNaming
  /// What a first start does once SSH answers (R-1001: `provision`).
  public nonisolated let provisioner: any GuestProvisioning

  var busy: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  /// The cross-process operation lock of each VM this manager is acting on (R-1100).
  private var operationLocks: [String: FileLock] = [:]

  public init(
    store: Store, backends: BackendRegistry = Backends.shared,
    readiness: any GuestReadiness = SSHReadiness(), keygen: any CommandRunning = ProcessRunner(),
    provisioner: any GuestProvisioning = SSHProvisioner(),
    manifests: (any GuestManifestTaker)? = nil, segments: SegmentStore? = nil,
    naming: any SegmentNaming = SSHSegmentHosts()
  ) {
    self.naming = naming
    self.segments = segments ?? SegmentStore(home: store.home)
    self.store = store
    self.backends = backends
    self.readiness = readiness
    self.keygen = keygen
    self.provisioner = provisioner
    self.manifests = manifests
  }

  /// What a lifecycle action left: the record (nil once destroyed) and warnings for the result,
  /// such as `ssh_unreachable` when a started guest never answered SSH.
  public struct Outcome: Sendable {
    public var record: VMRecord?
    public var warnings: [String]

    public init(record: VMRecord?, warnings: [String] = []) {
      self.record = record
      self.warnings = warnings
    }
  }

  // MARK: Create

  /// Stores a new VM from `plan` (profile, guest, features and resources come from the plan; name,
  /// image and network from `record`) and has its backend create it. If the backend fails or the
  /// task is cancelled, whatever was made is destroyed and no VM directory is left.
  public func create(_ record: VMRecord, plan: Plan) async throws(VMLabError) -> VMRecord {
    let backend = try backends.backend(for: plan.profile)
    var new = record
    new.profile = plan.profile
    new.guest = plan.guest
    new.features = plan.features
    new.resources = plan.resources
    new.state = .created
    new.runtime = nil
    new.checkpoints = []
    new.plan = plan
    // R-1102: a share's host directory is model-supplied; it must pass the path policy and is
    // recorded canonical, so a symlink swapped in later does not move it.
    if let host = new.share?.host {
      new.share?.host = try PathPolicy.load(home: store.home).check(host, field: "share.host").path
    }
    var stored = try store.create(new)
    do throws(VMLabError) {
      if let name = Self.segmentName(of: stored) {
        let attachment = try segments.join(name, vm: stored)
        stored = try store.update(id: stored.id) { $0.segment = attachment }
      }
      try await SSHKeys.generateDetached(
        in: store.directory(of: stored.id), comment: "vmlab-\(stored.id)", runner: keygen)
      try await backend.create(stored, plan: plan)
      if Task.isCancelled { throw Self.cancelled("create", vm: stored.id) }
    } catch {
      // In a task of its own, which a cancelled caller does not cancel, so the cleanup runs whole.
      let store = store
      let segments = segments
      let failed = stored
      await Task {
        try? await backend.destroy(failed)
        if let name = Self.segmentName(of: failed) { try? segments.leave(name, vm: failed.id) }
        try? store.remove(id: failed.id)
      }.value
      throw error
    }
    await log(stored.id, "created (\(plan.profile.rawValue))")
    return stored
  }

  // MARK: Lifecycle

  /// Performs `action` on the VM named or identified by `vm`. Returns the updated record, or nil
  /// once the VM is destroyed. `checkpoint_stop` takes a temporary live checkpoint and ends the
  /// engine, leaving the VM `suspended`; starting a suspended VM restores that checkpoint.
  @discardableResult
  public func perform(
    _ action: LifecycleAction, on vm: String, force: Bool = false, timeout: Duration? = nil
  ) async throws(VMLabError) -> VMRecord? {
    try await run(action, on: vm, force: force, timeout: timeout).record
  }

  /// `perform`, with the warnings the action produced. A start of a VM granted `exec_ssh` records
  /// `running` with its runtime as soon as the engine is up (so a crash of this process leaves a
  /// record to reattach to), then waits, still holding the VM's lock, until SSH answers or the
  /// boot timeout (Appendix G) passes; a guest that never answers stays `running` with an
  /// `ssh_unreachable` warning. `destroy` refuses (`invalid_request`, field `force`) while
  /// another VM's backing chain reads a file of this one, unless `force`, which destroys it all
  /// the same and warns that those VMs can no longer boot.
  ///
  /// `timeout` (`vm_lifecycle timeoutSeconds`) is, for `start`, how long to wait for SSH (default
  /// the Appendix G boot timeout) and, for `stop`, the grace period after the power button
  /// (default the engine's, Appendix G: 60 s for QEMU): a guest still up then is killed, the VM
  /// ends `stopped` and a warning says so. Other actions ignore it.
  public func run(
    _ action: LifecycleAction, on vm: String, force: Bool = false, timeout: Duration? = nil,
    sshTimeout: Duration? = nil
  ) async throws(VMLabError) -> Outcome {
    let id = try store.find(vm).id
    await acquire(id)
    defer { release(id) }
    let record = try store.load(id: id)
    let target = try Lifecycle.transition(action, from: record.state, vm: record.id)
    let backend = try backends.backend(for: record.profile)
    var warnings: [String] = []
    if action == .destroy {
      let dependents = try dependents(of: record)
      if !dependents.isEmpty {
        let names = dependents.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        guard force else {
          throw VMLabError(
            code: .invalidRequest,
            message: "VM \(id)'s disk backs the disk of \(names)",
            hint: "Destroy those VMs first, or pass force: true to destroy this one anyway "
              + "(they will no longer boot).",
            data: [
              "field": .string("force"), "reason": .string("other VMs depend on this disk"),
              "vm": .string(id), "dependents": .array(dependents.map { .string($0.id) }),
            ])
        }
        warnings.append("destroyed with force: \(names) read its disk and can no longer boot")
      }
    }
    do {
      let updated = try await apply(
        action, target: target, to: record, with: backend, timeout: timeout,
        warnings: &warnings)
      if action == .start, let updated {
        let ready = await waitForSSH(updated, backend: backend, timeout: sshTimeout ?? timeout)
        if let warning = ready.warning {
          warnings.append(warning)
          if warning != Self.noEndpoint(id) { await log(id, warning, level: .warning) }
        } else if let target = ready.target {
          for warning in await provisioner.provision(updated, target: target) {
            warnings.append(warning)
            await log(id, warning, level: .warning)
          }
          if let segment = updated.segment {
            warnings += await publishNames(segment.segment, focus: id)
          }
        }
      } else if action == .destroy, let segment = record.segment {
        _ = await publishNames(segment.segment, focus: id)
      }
      return Outcome(record: updated, warnings: warnings)
    } catch {
      await log(id, "\(action.rawValue) failed: \(error.message)", kind: .error, level: .error)
      if DeadPeer.isDeadPeer(error) {
        await store.markBroken(id: id, reason: DeadPeer.reason(of: error))
      }
      throw error
    }
  }

  private func apply(
    _ action: LifecycleAction, target: LifecycleTarget, to record: VMRecord,
    with backend: any Backend, timeout: Duration? = nil, warnings: inout [String]
  ) async throws(VMLabError) -> VMRecord? {
    var runtime = record.runtime
    switch action {
    case .start:
      if let segment = record.segment { try await segments.startSwitch(segment.segment) }
      runtime = try await backend.start(record)
      if record.state == .suspended, let started = runtime {
        try await resumeSuspended(record, runtime: started, with: backend)
      }
    case .stop:
      do {
        try await backend.stop(record, grace: timeout)
      } catch  where error.code == .timeout && error.data["cancelled"] == nil && !Task.isCancelled {
        // The grace period is over: kill, as the tool promises (ACPI, then kill).
        try await backend.kill(record)
        let warning =
          "stop: the guest did not shut down within its grace period "
          + "(\(Self.seconds(timeout))), so it was killed"
        warnings.append(warning)
        await log(record.id, warning, level: .warning)
      }
    case .kill: try await backend.kill(record)
    case .pause: try await backend.pause(record)
    case .resume: try await backend.resume(record)
    case .reset: runtime = try await backend.reset(record)
    case .destroy:
      if record.state.isLive || record.runtime != nil { try await backend.kill(record) }
      try await backend.destroy(record)
      if let segment = record.segment { try? segments.leave(segment.segment, vm: record.id) }
      try store.remove(id: record.id)
      return nil
    case .checkpointStop:
      try await checkpointStop(record, with: backend)
    }
    guard case .state(let state) = target else { return nil }
    if !state.isLive { runtime = nil }
    let updated = try store.update(id: record.id) { (current: inout VMRecord) throws(VMLabError) in
      guard current.state == record.state else {
        throw Lifecycle.wrongState(action: action, state: current.state, vm: current.id)
      }
      current.state = state
      current.runtime = runtime
      if state != .broken { current.brokenReason = nil }
    }
    await log(record.id, "\(action.rawValue): \(record.state.rawValue) -> \(state.rawValue)")
    return updated
  }

  /// The target when the guest answered SSH; neither when it is not one to wait for (no
  /// `exec_ssh`, networking off); otherwise the warning.
  private func waitForSSH(
    _ record: VMRecord, backend: any Backend, timeout limit: Duration? = nil
  ) async -> (target: SSHTarget?, warning: String?) {
    guard record.features.contains(.execSSH), record.network.mode != .disabled else {
      return (nil, nil)
    }
    let timeout =
      limit ?? ResourceLimits.bootTimeout(profile: record.profile, os: record.guest.os)
    guard let endpoint = await backend.sshEndpoint(record, timeout: timeout) else {
      return (nil, Self.noEndpoint(record.id))
    }
    let target = SSHTarget(record: record, endpoint: endpoint, store: store)
    if let warning = await readiness.wait(for: target, timeout: timeout) { return (nil, warning) }
    return (target, nil)
  }

  /// "60 s", or "the engine's default" for nil.
  static func seconds(_ duration: Duration?) -> String {
    guard let duration else { return "the engine's default" }
    return "\(duration.components.seconds) s"
  }

  /// The segment a new VM joins: its request's `network.segment`, unless networking is off.
  static func segmentName(of record: VMRecord) -> String? {
    guard record.network.mode != .disabled else { return nil }
    return record.network.segment
  }

  static func noEndpoint(_ id: String) -> String {
    "ssh_unreachable: \(id) has no SSH endpoint (no forwarded port or address); it is running, "
      + "retry vm_exec later or read vm_serial"
  }

  /// The SSH target of a live VM, as its backend reports the endpoint now.
  public func sshTarget(_ vm: String) async throws(VMLabError) -> SSHTarget {
    let record = try store.find(vm)
    let backend = try backends.backend(for: record.profile)
    guard let endpoint = await backend.sshEndpoint(record, timeout: .zero) else {
      throw VMLabError(
        code: .guestUnreachable, message: "VM \(record.id) has no SSH endpoint yet",
        hint: "Wait for the guest to finish booting (vm_serial shows it) and try again.",
        data: ["vm": .string(record.id), "tried": .array([.string("ssh")])])
    }
    return SSHTarget(record: record, endpoint: endpoint, store: store)
  }

  // MARK: Attach

  /// The channels of a running or paused VM; `wrong_state` in any other state.
  public func attach(_ vm: String) async throws(VMLabError) -> any RunningVM {
    let record = try store.find(vm)
    guard record.state.isLive else {
      let legal = Lifecycle.legalActions(in: record.state).map(\.rawValue)
      throw VMLabError(
        code: .wrongState,
        message: "VM \(record.id) is \(record.state.rawValue); its channels need it running",
        hint: legal.contains("start")
          ? "Start it with vm_lifecycle start." : "Allowed: \(legal.joined(separator: ", ")).",
        data: [
          "vm": .string(record.id), "state": .string(record.state.rawValue),
          "legalActions": .array(legal.map { .string($0) }),
        ])
    }
    return try await backends.backend(for: record.profile).attach(record)
  }

  /// Attaches every running or paused guest's backend, so the server watches what it did not
  /// start itself (R-304 panic detection on serial and QMP events, R-1101 dead-peer detection)
  /// from the moment it starts, not only once a tool touches the VM. Failures are ignored: the
  /// next tool call on that VM reports them.
  public func monitorLiveGuests() async {
    for record in (try? store.list().records) ?? [] where record.state.isLive {
      _ = try? await attach(record.id)
    }
  }

  // MARK: Helpers

  /// Serializes actions on `id`: first among this process's callers, then, through the VM's
  /// operation lock file, with every other `vmlab` process on the same home (R-1100).
  func acquire(_ id: String) async {
    while busy.contains(id) {
      await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
    busy.insert(id)
    operationLocks[id] = await FileLock.lock(store.operationLockPath(of: id))
  }

  func release(_ id: String) {
    operationLocks.removeValue(forKey: id)?.unlock()
    busy.remove(id)
    if var queue = waiters[id], !queue.isEmpty {
      queue.removeFirst().resume()
      waiters[id] = queue.isEmpty ? nil : queue
    }
  }

  func log(
    _ id: String, _ message: String, kind: VMEvent.Kind = .lifecycle, level: Logger.Level = .info
  ) async {
    let log = EventLog(vmDirectory: store.directory(of: id))
    try? await log.append(kind, message, level: level)
  }

  /// The refusal of an operation whose task was cancelled (MCP `notifications/cancelled`).
  public static func cancelled(_ what: String, vm: String) -> VMLabError {
    VMLabError(
      code: .timeout, message: "\(what) of \(vm) was cancelled",
      hint: "Nothing was kept; call it again to retry.",
      data: ["vm": .string(vm), "cancelled": .bool(true)])
  }
}
