import Foundation
import VMLabCore

/// `vm_file`: copies between the host and a running guest over the VM's SSH channel (R-404),
/// recursively, with `scp` in SFTP mode. `push` needs `local`; `pull` without `local` lands in
/// `<vm>/pulled/`. Host paths must be absolute and pass the `PathPolicy` (R-1102): `push` reads
/// under the user's home, `/tmp` or `$TMPDIR`, never a dot entry at the top of the home,
/// `~/Library`, `VMLAB_HOME` or a credential name (`.env`, `id_ed25519`), and a directory's
/// entries refused so (through its symlinks) are skipped and listed in `skipped`; `pull` writes only under `/tmp`, `$TMPDIR`,
/// `~/vmlab-files` or the owner's `writeRoots`, never a dotfile in the home, `~/Library` or
/// `VMLAB_HOME`. A heartbeat is reported while the copy runs.
struct VMFileHandler: ToolHandler {
  var spec: ToolSpec { .vmFile }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let record = try context.store.find(try arguments.string("vm") ?? "")
    let action = try arguments.string("action") ?? ""
    guard action == "push" || action == "pull" else {
      throw VMLabError.invalidRequest(
        field: "action", reason: "action must be push or pull", hint: "Pick push or pull.")
    }
    let remote = try arguments.string("remote") ?? ""
    let policy = PathPolicy.load(home: context.home)
    let local = try Self.localPath(
      try arguments.string("local"), policy: policy, access: action == "push" ? .read : .write)
    // A pushed directory's refused entries are skipped and reported, not the whole push refused.
    if action == "push", local == nil {
      throw VMLabError.invalidRequest(
        field: "local", reason: "push needs the host path to copy",
        hint: "Give local, the absolute host path of a file or directory.")
    }
    let vm = try await context.manager.attach(record.id)
    let transfer = SSHFileTransfer(target: try VMExecHandler.sshChannel(of: vm).target)
    let result = try await context.progress.during(
      "copying files \(action == "push" ? "to" : "from") \(record.id)", every: context.heartbeat
    ) { () throws(VMLabError) -> FileTransferResult in
      if action == "push", let local {
        return try await transfer.push(local: local, remote: remote, policy: policy)
      }
      return try await transfer.pull(remote: remote, local: local, policy: policy)
    }
    var object: [String: JSONValue] = [
      "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
      "bytes": .number(Double(result.bytes)),
      "path": .string(result.path),
    ]
    var warnings: [String] = []
    if !result.skipped.isEmpty {
      object["skipped"] = .array(
        result.skipped.map { .object(["path": .string($0.path), "reason": .string($0.reason)]) })
      warnings.append(
        "\(result.skipped.count) host entr\(result.skipped.count == 1 ? "y was" : "ies were") not "
          + "copied (credentials, ~/ dot entries, ~/Library, VMLAB_HOME or links leading there); "
          + "see skipped. The owner can list a folder in readRoots in config.json.")
    }
    return ToolResult(object, warnings: warnings)
  }

  /// An absolute host path, canonicalised and checked against `policy` for `access` (a pull
  /// writes it); `invalid_request` for a relative one or one the policy refuses.
  static func localPath(_ value: String?, policy: PathPolicy, access: PathPolicy.Access)
    throws(VMLabError) -> URL?
  {
    guard let value else { return nil }
    return try policy.check(value, field: "local", access: access, wholeTree: false)
  }
}
