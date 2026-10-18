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

  private var busy: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  public init(store: Store, backends: BackendRegistry = Backends.shared) {
    self.store = store
    self.backends = backends
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
  /// once the VM is destroyed. `checkpoint_stop` belongs to `vm_checkpoint` (R-800) and is refused.
  @discardableResult
  public func perform(
    _ action: LifecycleAction, on vm: String
  ) async throws(VMLabError) -> VMRecord? {
    let id = try store.find(vm).id
    await acquire(id)
    defer { release(id) }
    let record = try store.load(id: id)
    let target = try Lifecycle.transition(action, from: record.state, vm: record.id)
    let backend = try backends.backend(for: record.profile)
    do {
      return try await apply(action, target: target, to: record, with: backend)
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
    case .start: runtime = try await backend.start(record)
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
      throw VMLabError.invalidRequest(
        field: "action", reason: "checkpoint_stop is not a vm_lifecycle action",
        hint: "Use vm_checkpoint create with mode live to save and stop the guest.")
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

  private func acquire(_ id: String) async {
    while busy.contains(id) {
      await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
    busy.insert(id)
  }

  private func release(_ id: String) {
    busy.remove(id)
    if var queue = waiters[id], !queue.isEmpty {
      queue.removeFirst().resume()
      waiters[id] = queue.isEmpty ? nil : queue
    }
  }

  private func log(
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
