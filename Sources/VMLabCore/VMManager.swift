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

  private var busy: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  public init(
    store: Store, backends: BackendRegistry = Backends.shared,
    readiness: any GuestReadiness = SSHReadiness(), keygen: any CommandRunning = ProcessRunner(),
    manifests: (any GuestManifestTaker)? = nil
  ) {
    self.store = store
    self.backends = backends
    self.readiness = readiness
    self.keygen = keygen
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
    let stored = try store.create(new)
    do throws(VMLabError) {
      try await SSHKeys.generateDetached(
        in: store.directory(of: stored.id), comment: "vmlab-\(stored.id)", runner: keygen)
      try await backend.create(stored, plan: plan)
      if Task.isCancelled { throw Self.cancelled("create", vm: stored.id) }
    } catch {
      // In a task of its own, which a cancelled caller does not cancel, so the cleanup runs whole.
      let store = store
      await Task {
        try? await backend.destroy(stored)
        try? store.remove(id: stored.id)
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
    _ action: LifecycleAction, on vm: String, force: Bool = false
  ) async throws(VMLabError) -> VMRecord? {
    try await run(action, on: vm, force: force).record
  }

  /// `perform`, with the warnings the action produced. A start of a VM granted `exec_ssh` records
  /// `running` with its runtime as soon as the engine is up (so a crash of this process leaves a
  /// record to reattach to), then waits, still holding the VM's lock, until SSH answers or the
  /// boot timeout (Appendix G) passes; a guest that never answers stays `running` with an
  /// `ssh_unreachable` warning. `destroy` refuses (`invalid_request`, field `force`) while
  /// another VM's backing chain reads a file of this one, unless `force`, which destroys it all
  /// the same and warns that those VMs can no longer boot.
  public func run(
    _ action: LifecycleAction, on vm: String, force: Bool = false
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
      let updated = try await apply(action, target: target, to: record, with: backend)
      if action == .start, let updated, let warning = await waitForSSH(updated, backend: backend) {
        warnings.append(warning)
        if warning != Self.noEndpoint(id) { await log(id, warning, level: .warning) }
      }
      return Outcome(record: updated, warnings: warnings)
    } catch {
      await log(id, "\(action.rawValue) failed: \(error.message)", kind: .error, level: .error)
      throw error
    }
  }

  private func apply(
    _ action: LifecycleAction, target: LifecycleTarget, to record: VMRecord,
    with backend: any Backend
  ) async throws(VMLabError) -> VMRecord? {
    var runtime = record.runtime
    switch action {
    case .start:
      runtime = try await backend.start(record)
      if record.state == .suspended, let started = runtime {
        try await resumeSuspended(record, runtime: started, with: backend)
      }
    case .stop: try await backend.stop(record)
    case .kill: try await backend.kill(record)
    case .pause: try await backend.pause(record)
    case .resume: try await backend.resume(record)
    case .reset: runtime = try await backend.reset(record)
    case .destroy:
      if record.state.isLive || record.runtime != nil { try await backend.kill(record) }
      try await backend.destroy(record)
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
    }
    await log(record.id, "\(action.rawValue): \(record.state.rawValue) -> \(state.rawValue)")
    return updated
  }

  /// Nil when the guest answered SSH or is not one to wait for (no `exec_ssh`, networking off);
  /// otherwise the warning.
  private func waitForSSH(_ record: VMRecord, backend: any Backend) async -> String? {
    guard record.features.contains(.execSSH), record.network.mode != .disabled else { return nil }
    let timeout = ResourceLimits.bootTimeout(profile: record.profile, os: record.guest.os)
    guard let endpoint = await backend.sshEndpoint(record, timeout: timeout) else {
      return Self.noEndpoint(record.id)
    }
    let target = SSHTarget(record: record, endpoint: endpoint, store: store)
    return await readiness.wait(for: target, timeout: timeout)
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

  // MARK: Helpers

  func acquire(_ id: String) async {
    while busy.contains(id) {
      await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
    busy.insert(id)
  }

  func release(_ id: String) {
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
