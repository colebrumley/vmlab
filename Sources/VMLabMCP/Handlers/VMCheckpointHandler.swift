import Foundation
import VMLabCore

/// `vm_checkpoint`: the checkpoint tree through `VMManager` (R-800); `diff` compares manifests
/// (R-802, `CheckpointDiff`).
struct VMCheckpointHandler: ToolHandler {
  var spec: ToolSpec { .vmCheckpoint }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let vm = try arguments.string("vm") ?? ""
    let action = try arguments.string("action") ?? ""
    let record = try context.store.find(vm)
    let manager = context.manager
    var result: [String: JSONValue] = [
      "vm": .object(["id": .string(record.id), "name": .string(record.name)])
    ]
    var warnings: [String] = []
    switch action {
    case "create":
      let name = try Self.name(arguments)
      let modeName = try arguments.string("mode") ?? CheckpointModeRequest.auto.rawValue
      guard let mode = CheckpointModeRequest(rawValue: modeName) else {
        throw VMLabError.invalidRequest(
          field: "mode", reason: "unknown mode \(modeName)", hint: "Use auto, disk or live.")
      }
      let manifest = try arguments.bool("manifest")
      let note = try arguments.string("note")
      let made = try await context.progress.during(
        "checkpoint \(name) of \(record.id)", every: context.heartbeat
      ) { () throws(VMLabError) -> CheckpointCreation in
        try await manager.createCheckpoint(
          record.id, name: name, mode: mode, manifest: manifest, note: note)
      }
      result["checkpoint"] = made.node.json
      warnings += made.warnings
    case "list":
      let tree = try await manager.checkpoints(of: record.id)
      result.merge(tree.json.objectValue ?? [:]) { $1 }
    case "restore":
      let name = try Self.name(arguments)
      let restored = try await context.progress.during(
        "restoring \(name) of \(record.id)", every: context.heartbeat
      ) { () throws(VMLabError) -> CheckpointNode in
        try await manager.restoreCheckpoint(record.id, name: name).node
      }
      result["checkpoint"] = restored.json
      result["state"] = .string(try context.store.load(id: record.id).state.rawValue)
    case "delete":
      let name = try Self.name(arguments)
      let recursive = try arguments.bool("recursive")
      let deleted = try await manager.deleteCheckpoint(record.id, name: name, recursive: recursive)
      result["deleted"] = .array(deleted.map { .string($0.name) })
    case "diff":
      let store = context.store
      return try await CheckpointDiff.run(arguments, record: record, context: context) {
        name throws(VMLabError) in
        let tree = try store.checkpoints(of: record.id)
        let node =
          name == CheckpointTree.latest ? tree.nodes.last : tree.nodes.first { $0.name == name }
        return node.map { ($0.name, $0.manifestPath) }
      }
    default:
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(action) is not a vm_checkpoint action",
        hint: "Use one of: create, list, restore, delete, diff.")
    }
    return ToolResult(result, warnings: warnings)
  }

  static func name(_ arguments: ToolArguments) throws(VMLabError) -> String {
    guard let name = try arguments.string("name"), !name.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "this action needs a checkpoint name",
        hint: "Pass name (or @latest for the newest checkpoint).")
    }
    return name
  }
}
