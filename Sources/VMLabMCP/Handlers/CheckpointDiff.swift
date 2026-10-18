import Foundation
import VMLabCore

/// `vm_checkpoint diff` (R-802): compares two manifests of one VM. Each side is `@now` (a
/// manifest taken now, with the other side's profile and paths when that one is stored), a
/// manifest id, or a checkpoint whose node has a manifest (`checkpointManifest` resolves it).
/// Each section returns at most `entryLimit` entries; the whole diff is saved beside the
/// manifests and its path returned.
enum CheckpointDiff {
  static let entryLimit = 500
  static let now = "@now"

  /// Resolves a checkpoint name (or `@latest`) to its name and the path of its manifest, if it
  /// has one; nil when the VM has no checkpoint of that name.
  typealias CheckpointManifest = (String) throws(VMLabError) -> (
    name: String, manifestPath: String?
  )?

  static func run(
    _ arguments: ToolArguments, record: VMRecord, context: ToolContext,
    checkpointManifest: CheckpointManifest
  ) async throws(VMLabError) -> ToolResult {
    guard let from = try arguments.string("from"), !from.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "from", reason: "diff needs from",
        hint: "Pass from and to: a checkpoint name, a manifest id or @now.")
    }
    guard let to = try arguments.string("to"), !to.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "to", reason: "diff needs to",
        hint: "Pass from and to: a checkpoint name, a manifest id or @now.")
    }
    guard from != now || to != now else {
      throw VMLabError.invalidRequest(
        field: "to", reason: "from and to are both @now",
        hint: "Compare @now with a checkpoint or a manifest id taken earlier.")
    }
    let storedFrom =
      from == now ? nil : try load(from, field: "from", record: record, context, checkpointManifest)
    let storedTo =
      to == now ? nil : try load(to, field: "to", record: record, context, checkpointManifest)
    var warnings: [String] = []
    func takeNow(like other: GuestManifest?) async throws(VMLabError) -> GuestManifest {
      let manifest = try await VMManifestHandler.take(
        record, profile: other?.profile ?? ManifestProfile(os: record.guest.os),
        paths: other?.roots ?? [], context: context)
      warnings += manifest.warnings
      return manifest
    }
    let old: GuestManifest
    if let storedFrom { old = storedFrom } else { old = try await takeNow(like: storedTo) }
    let new: GuestManifest
    if let storedTo { new = storedTo } else { new = try await takeNow(like: storedFrom) }
    let diff = ManifestDiff(from: old, to: new)
    warnings += diff.warnings
    let path = try context.store.saveManifestDiff(diff, vm: record.id)
    var result = try render(diff)
    result["vm"] = .object(["id": .string(record.id), "name": .string(record.name)])
    result["from"] = .string(old.id)
    result["to"] = .string(new.id)
    result["path"] = .string(path.path)
    return ToolResult(result, warnings: warnings)
  }

  /// The stored manifest a side names: a manifest id, else a checkpoint with a manifest.
  static func load(
    _ side: String, field: String, record: VMRecord, _ context: ToolContext,
    _ checkpointManifest: CheckpointManifest
  ) throws(VMLabError) -> GuestManifest {
    if GuestManifest.isValidID(side) {
      return try context.store.loadManifest(vm: record.id, id: side, field: field)
    }
    guard let checkpoint = try checkpointManifest(side) else {
      throw VMLabError.invalidRequest(
        field: field, reason: "\(record.id) has no manifest or checkpoint named \(side)",
        hint: "Use @now, a manifest id from vm_manifest, or a checkpoint name from "
          + "vm_checkpoint list.")
    }
    guard let path = checkpoint.manifestPath else {
      throw VMLabError.invalidRequest(
        field: field, reason: "checkpoint \(checkpoint.name) has no manifest",
        hint: "Create checkpoints with manifest: true while the guest runs, or compare with "
          + "@now or a manifest id.")
    }
    return try context.store.loadManifest(at: URL(filePath: path), field: field)
  }

  /// Each section as `{ added, removed, changed, entries, truncated }`, entries capped.
  static func render(_ diff: ManifestDiff) throws(VMLabError) -> [String: JSONValue] {
    func section<Entry: Encodable>(_ name: String, _ entries: [Entry]) throws(VMLabError)
      -> JSONValue
    {
      let counts = diff.counts(name)
      return .object([
        "added": .number(Double(counts.added)), "removed": .number(Double(counts.removed)),
        "changed": .number(Double(counts.changed)),
        "entries": try JSONValue(encoding: Array(entries.prefix(entryLimit))),
        "truncated": .bool(entries.count > entryLimit),
      ])
    }
    return [
      "files": try section("files", diff.files),
      "packages": try section("packages", diff.packages),
      "services": try section("services", diff.services),
      "defaults": try section("defaults", diff.defaults),
      "users": try section("users", diff.users),
      "loginItems": try section("loginItems", diff.loginItems),
      "profiles": try section("profiles", diff.profiles),
    ]
  }
}
