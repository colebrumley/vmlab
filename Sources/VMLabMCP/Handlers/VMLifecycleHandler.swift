import Foundation
import VMLabCore

/// `vm_lifecycle`: one power transition through `VMManager`. `start` runs under the start gate
/// and reports progress while the guest boots; `clone` (R-803) makes a new VM, in state `created`,
/// from the VM's current disk or from checkpoint `from`.
struct VMLifecycleHandler: ToolHandler {
  var spec: ToolSpec { .vmLifecycle }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let vm = try arguments.string("vm") ?? ""
    let actionName = try arguments.string("action") ?? ""
    if actionName == "clone" { return try await clone(vm, arguments, context: context) }
    guard let action = LifecycleAction(rawValue: actionName), action != .checkpointStop else {
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(actionName) is not a vm_lifecycle action",
        hint: "Use one of: start, stop, kill, pause, resume, reset, destroy, clone.")
    }
    var warnings: [String] = []
    if try arguments.int("timeoutSeconds") != nil {
      warnings.append("timeoutSeconds is not honoured yet; the backend's default applies")
    }
    let force = try arguments.bool("force")

    let record = try context.store.find(vm)
    let started = ContinuousClock.now
    let after: VMRecord?
    switch action {
    case .start:
      let started = try await LongOperation.start(record, context: context)
      after = started.record
      warnings += started.warnings
    default:
      let manager = context.manager
      let outcome = try await context.progress.during(
        "\(action.rawValue) \(record.id)", every: context.heartbeat
      ) { () throws(VMLabError) -> VMManager.Outcome in
        try await manager.run(action, on: record.id, force: force)
      }
      after = outcome.record
      warnings += outcome.warnings
    }
    // vm_debug's session follows the guest (R-703): a reset may clear the CPU's debug registers,
    // so its points go in again; a destroyed VM's session goes.
    if action == .reset, let session = context.debug.existing(record.id) {
      do {
        try await session.afterReset(halted: record.boot?.haltAtStart == true)
      } catch {
        warnings.append("the debugger could not insert its breakpoints again: \(error.message)")
      }
    } else if action == .destroy {
      await context.debug.drop(record.id)
    }
    let elapsed = ContinuousClock.now - started
    let ms = (elapsed / .milliseconds(1)).rounded()
    return ToolResult(
      [
        "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
        "state": .string(after?.state.rawValue ?? "destroyed"),
        "durationMs": .number(ms),
      ], warnings: warnings)
  }

  func clone(
    _ vm: String, _ arguments: ToolArguments, context: ToolContext
  ) async throws(VMLabError) -> ToolResult {
    let name = try arguments.string("name")
    let from = try arguments.string("from")
    let source = try context.store.find(vm)
    let manager = context.manager
    let started = ContinuousClock.now
    let clone = try await context.progress.during(
      "cloning \(source.id)", every: context.heartbeat
    ) { () throws(VMLabError) -> VMRecord in
      try await manager.clone(source.id, name: name, from: from)
    }
    let ms = ((ContinuousClock.now - started) / .milliseconds(1)).rounded()
    var result: [String: JSONValue] = [
      "vm": .object(["id": .string(clone.id), "name": .string(clone.name)]),
      "source": .object(["id": .string(source.id), "name": .string(source.name)]),
      "state": .string(clone.state.rawValue),
      "durationMs": .number(ms),
      "backingChain": .array((clone.backingChain ?? []).map { .string($0) }),
    ]
    if let plan = clone.plan { result["plan"] = try JSONValue(encoding: plan) }
    if let checkpoint = clone.clonedFrom?.checkpointName {
      result["from"] = .string(checkpoint)
    }
    return ToolResult(result)
  }
}
