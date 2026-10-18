import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab exec`: the vm_exec tool.
struct ExecCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "exec",
    abstract: "Run a shell command in a running guest (the vm_exec tool).")
  static let toolName = "vm_exec"

  @Argument(help: "The VM's id or name.") var vm: String
  @Argument(help: "The command, run by the guest's shell.") var command: String
  @Option(help: "Kill the command after this many seconds (default 120).") var timeoutSeconds: Int?
  @Option(help: "Working directory in the guest.") var cwd: String?
  @Option(help: "An environment variable, NAME=value (repeatable).") var env: [String] = []
  @Option(help: "Text fed to the command's standard input.") var stdin: String?
  @Option(help: "Run as this guest user (sudo).") var user: String?
  @Option(help: "auto, ssh or agent.") var via: String?
  @Flag(help: "Return a job id at once; follow it with vmlab job.") var background = false
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = ["vm": .string(vm), "command": .string(command)]
    if let timeoutSeconds { object["timeoutSeconds"] = .number(Double(timeoutSeconds)) }
    if let cwd { object["cwd"] = .string(cwd) }
    if !env.isEmpty {
      var variables: [String: JSONValue] = [:]
      for pair in env {
        guard let equals = pair.firstIndex(of: "=") else {
          throw ValidationError("--env takes NAME=value, got \(pair)")
        }
        variables[String(pair[..<equals])] = .string(String(pair[pair.index(after: equals)...]))
      }
      object["env"] = .object(variables)
    }
    if let stdin { object["stdin"] = .string(stdin) }
    if let user { object["user"] = .string(user) }
    if let via { object["via"] = .string(via) }
    if background { object["background"] = .bool(true) }
    return .object(object)
  }

  /// stdout as the guest wrote it; stderr, the log path and a non-zero status go to stderr.
  func render(_ result: ToolResult) -> String {
    if let job = result.value["job"]?.stringValue { return job }
    var notes: [String] = []
    if let stderr = result.value["stderr"]?.stringValue, !stderr.isEmpty { notes.append(stderr) }
    if let log = result.value["logPath"]?.stringValue {
      notes.append("output truncated; see \(log)\n")
    }
    let code = Int(result.value["exitCode"]?.numberValue ?? 0)
    if code != 0 { notes.append("exit \(code)\n") }
    if !notes.isEmpty { FileHandle.standardError.write(Data(notes.joined().utf8)) }
    var out = result.value["stdout"]?.stringValue ?? ""
    if out.hasSuffix("\n") { out.removeLast() }
    return out
  }
}

/// `vmlab job`: the vm_job tool.
struct JobCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "job",
    abstract: "Read, wait for or kill a background command (the vm_job tool).")
  static let toolName = "vm_job"

  @Argument(help: "The VM's id or name.") var vm: String
  @Argument(help: "The job id vmlab exec --background printed.") var job: String
  @Argument(help: "read, wait or kill.") var action: String
  @Option(help: "wait: the longest to block, in seconds (default 60).") var timeoutSeconds: Int?
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = [
      "vm": .string(vm), "job": .string(job), "action": .string(action),
    ]
    if let timeoutSeconds { object["timeoutSeconds"] = .number(Double(timeoutSeconds)) }
    return .object(object)
  }

  /// The new output; whether the job finished goes to stderr.
  func render(_ result: ToolResult) -> String {
    let status =
      result.value["finished"] == .bool(true)
      ? "finished, exit \(Int(result.value["exitCode"]?.numberValue ?? -1))" : "running"
    FileHandle.standardError.write(Data("job \(job): \(status)\n".utf8))
    var out = result.value["output"]?.stringValue ?? ""
    if out.hasSuffix("\n") { out.removeLast() }
    return out
  }
}

/// `vmlab file`: the vm_file tool.
struct FileCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "file",
    abstract: "Copy files to or from a running guest over SSH (the vm_file tool).")
  static let toolName = "vm_file"

  @Argument(help: "The VM's id or name.") var vm: String
  @Argument(help: "push or pull.") var action: String
  @Argument(help: "The path in the guest.") var remote: String
  @Argument(help: "The host path (push: required; pull: default the VM's pulled/ directory).")
  var local: String?
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = [
      "vm": .string(vm), "action": .string(action), "remote": .string(remote),
    ]
    if let local {
      let url = URL(filePath: local, relativeTo: URL.currentDirectory())
      object["local"] = .string(url.standardizedFileURL.path)
    }
    return .object(object)
  }

  func render(_ result: ToolResult) -> String {
    let bytes = Int(result.value["bytes"]?.numberValue ?? 0)
    return "\(bytes) bytes -> \(result.value["path"]?.stringValue ?? "")"
  }
}
