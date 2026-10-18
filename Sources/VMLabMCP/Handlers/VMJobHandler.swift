import Foundation
import VMLabCore

/// `vm_job`: follows a background command of `vm_exec` (R-402) through `ExecJobs`. `read` returns
/// the output since the last read; `wait` blocks up to `timeoutSeconds` (default 60) for the end;
/// `kill` ends the job's process group.
struct VMJobHandler: ToolHandler {
  static let defaultWaitSeconds = 60

  var spec: ToolSpec { .vmJob }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let record = try context.store.find(try arguments.string("vm") ?? "")
    let job = try arguments.string("job") ?? ""
    guard ExecJobs.isValidJobID(job) else {
      throw VMLabError.invalidRequest(
        field: "job", reason: "\(job) is not a job id",
        hint: "Use the job id vm_exec returned with background: true.")
    }
    let action = try arguments.string("action") ?? ""
    guard ["read", "wait", "kill"].contains(action) else {
      throw VMLabError.invalidRequest(
        field: "action", reason: "action must be read, wait or kill",
        hint: "Pick one of read, wait, kill.")
    }
    let seconds = try arguments.int("timeoutSeconds") ?? Self.defaultWaitSeconds
    guard seconds >= 1 else {
      throw VMLabError.invalidRequest(
        field: "timeoutSeconds", reason: "timeoutSeconds must be at least 1",
        hint: "Pass a positive number of seconds.")
    }
    let vm = try await context.manager.attach(record.id)
    let channel = try VMExecHandler.sshChannel(of: vm)
    let jobs = ExecJobs.shared
    let read: ExecJobRead
    switch action {
    case "wait":
      read = try await context.progress.during(
        "waiting for \(job) on \(record.id)", every: context.heartbeat
      ) { () throws(VMLabError) -> ExecJobRead in
        try await jobs.wait(job, on: channel, timeout: .seconds(seconds))
      }
    case "kill": read = try await jobs.kill(job, on: channel)
    default: read = try await jobs.read(job, on: channel)
    }
    var object: [String: JSONValue] = [
      "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
      "job": .string(job),
      "output": .string(read.output),
      "finished": .bool(read.finished),
      "more": .bool(read.more),
      "logPath": .string(read.logPath),
    ]
    if let code = read.exitCode { object["exitCode"] = .number(Double(code)) }
    return ToolResult(object, warnings: read.warnings)
  }
}
