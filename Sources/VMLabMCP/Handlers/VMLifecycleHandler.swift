import Foundation
import VMLabCore

/// `vm_lifecycle`: one power transition through `VMManager`. `start` runs under the start gate
/// and reports progress while the guest boots; `clone` belongs to R-803 and is refused until then.
struct VMLifecycleHandler: ToolHandler {
  var spec: ToolSpec { .vmLifecycle }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let vm = try arguments.string("vm") ?? ""
    let actionName = try arguments.string("action") ?? ""
    guard let action = LifecycleAction(rawValue: actionName), action != .checkpointStop else {
      if actionName == "clone" {
        throw VMLabError.invalidRequest(
          field: "action", reason: "clone is not built yet",
          hint: "Create a new VM with vm_create instead.")
      }
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(actionName) is not a vm_lifecycle action",
        hint: "Use one of: start, stop, kill, pause, resume, reset, destroy.")
    }
    var warnings: [String] = []
    if try arguments.int("timeoutSeconds") != nil {
      warnings.append("timeoutSeconds is not honoured yet; the backend's default applies")
    }
    if try arguments.bool("force") {
      warnings.append("force has no effect yet: no VM's disk is backed by another's")
    }

    let record = try context.store.find(vm)
    let started = ContinuousClock.now
    let after: VMRecord?
    switch action {
    case .start:
      after = try await LongOperation.start(record, context: context)
    default:
      let manager = context.manager
      after = try await context.progress.during(
        "\(action.rawValue) \(record.id)", every: context.heartbeat
      ) { () throws(VMLabError) -> VMRecord? in
        try await manager.perform(action, on: record.id)
      }
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
}
