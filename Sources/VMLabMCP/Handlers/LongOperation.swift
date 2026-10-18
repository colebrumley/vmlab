import Foundation
import VMLabCore

/// The steps the long calls share (R-205): an image pull and a guest start, each reporting
/// progress while it runs, and the mapping of a cancelled task to a refusal. MCP cancellation
/// (`notifications/cancelled`) cancels the Swift task of the call (the SDK does it); these steps
/// notice and stop, and `vm_create` destroys what it made.
enum LongOperation {
  /// The refusal of a call whose task was cancelled; `timeout` with `data.cancelled: true`.
  static func cancelled(_ what: String, vm: String? = nil) -> VMLabError {
    if let vm { return VMManager.cancelled(what, vm: vm) }
    return VMLabError(
      code: .timeout, message: "\(what) was cancelled",
      hint: "Nothing was kept; call it again to retry.", data: ["cancelled": .bool(true)])
  }

  static func checkCancellation(_ what: String, vm: String? = nil) throws(VMLabError) {
    if Task.isCancelled { throw cancelled(what, vm: vm) }
  }

  /// `body`, whose errors are untyped, with them as `VMLabError`: a cancellation is `cancelled`,
  /// anything that is not a `VMLabError` is `internal`.
  static func typed<T: Sendable>(
    _ what: String, vm: String? = nil, _ body: () async throws -> T
  ) async throws(VMLabError) -> T {
    do {
      return try await body()
    } catch let error as VMLabError {
      if Task.isCancelled, error.data["cancelled"] == nil { throw cancelled(what, vm: vm) }
      throw error
    } catch {
      if error is CancellationError || Task.isCancelled { throw cancelled(what, vm: vm) }
      throw ToolRendering.internalError(error, doing: what)
    }
  }

  /// Pulls `name` unless it is already pulled; nil when nothing was fetched.
  static func pullIfMissing(_ name: String, context: ToolContext) async throws(VMLabError)
    -> PullResult?
  {
    if context.images.pulled(name) != nil { return nil }
    return try await pull(name, context: context)
  }

  /// Pulls `name` (a no-op when current), with a heartbeat while it downloads.
  static func pull(_ name: String, context: ToolContext) async throws(VMLabError) -> PullResult {
    let images = context.images
    let result = try await context.progress.during(
      "pulling image \(name)", every: context.heartbeat
    ) { () throws(VMLabError) -> PullResult in
      try await typed("images pull \(name)") { try await images.pull(name) }
    }
    try checkCancellation("images pull \(name)")
    return result
  }

  /// Starts `record` under the start gate (slot, macOS count and memory budget), with a heartbeat
  /// while it boots. A legal-state check comes first, so a running VM is `wrong_state`, not a
  /// limit refusal.
  static func start(_ record: VMRecord, context: ToolContext) async throws(VMLabError)
    -> VMRecord
  {
    _ = try Lifecycle.transition(.start, from: record.state, vm: record.id)
    let store = context.store
    let manager = context.manager
    let gate = context.startGate
    let host = context.hostFacts()
    let started = try await context.progress.during(
      "starting \(record.id)", every: context.heartbeat
    ) { () throws(VMLabError) -> VMRecord? in
      try await typed("start", vm: record.id) {
        try await gate.withStart(
          Inventory.Guest(record: record), running: { store.inventory() }, host: host
        ) { try await manager.perform(.start, on: record.id) }
      }
    }
    guard let started else { return try store.load(id: record.id) }
    return started
  }
}
