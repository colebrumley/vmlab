import Foundation
import VMLabCore

/// `vm_file`: copies between the host and a running guest over the VM's SSH channel (R-404),
/// recursively, with `scp` in SFTP mode. `push` needs `local`; `pull` without `local` lands in
/// `<vm>/pulled/`. Host paths must be absolute. A heartbeat is reported while the copy runs.
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
    let local = try Self.localPath(try arguments.string("local"))
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
        return try await transfer.push(local: local, remote: remote)
      }
      return try await transfer.pull(remote: remote, local: local)
    }
    return ToolResult([
      "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
      "bytes": .number(Double(result.bytes)),
      "path": .string(result.path),
    ])
  }

  /// An absolute host path, standardised; `invalid_request` for a relative one.
  static func localPath(_ value: String?) throws(VMLabError) -> URL? {
    guard let value else { return nil }
    guard value.hasPrefix("/") else {
      throw VMLabError.invalidRequest(
        field: "local", reason: "\(value) is not an absolute path",
        hint: "Give the absolute host path, such as /Users/me/file.txt.")
    }
    return URL(filePath: value).standardizedFileURL
  }
}
