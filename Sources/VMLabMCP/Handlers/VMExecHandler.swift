import Foundation
import VMLabCore

/// `vm_exec`: one command in a running guest through its exec channel (R-401). `via` picks the
/// channel: `ssh` needs `exec_ssh`, `agent` needs `exec_agent` (R-403), `auto` takes SSH when it
/// was granted. A heartbeat is reported while the command runs.
struct VMExecHandler: ToolHandler {
  static let defaultTimeoutSeconds = 120

  var spec: ToolSpec { .vmExec }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let request = try Self.request(arguments)
    let record = try context.store.find(try arguments.string("vm") ?? "")
    if try arguments.bool("background") {
      throw VMLabError.invalidRequest(
        field: "background", reason: "background jobs are not built yet (R-402)",
        hint: "Run the command in the foreground with a larger timeoutSeconds.")
    }
    let vm = try await context.manager.attach(record.id)
    let channel = try Self.channel(of: vm, via: request.via)
    let result = try await context.progress.during(
      "running a command in \(record.id)", every: context.heartbeat
    ) { () throws(VMLabError) -> ExecResult in
      try await channel.run(request)
    }
    var object: [String: JSONValue] = [
      "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
      "exitCode": .number(Double(result.exitCode)),
      "stdout": .string(result.stdout),
      "stderr": .string(result.stderr),
      "durationMs": .number(Double(result.durationMs)),
      "truncated": .bool(result.truncated),
    ]
    if let log = result.logPath { object["logPath"] = .string(log) }
    return ToolResult(object)
  }

  /// The request the arguments describe; `invalid_request` for a malformed field.
  static func request(_ arguments: ToolArguments) throws(VMLabError) -> ExecRequest {
    let command = try arguments.string("command") ?? ""
    guard !command.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "command", reason: "command must not be empty", hint: "Pass the command to run.")
    }
    let seconds = try arguments.int("timeoutSeconds") ?? defaultTimeoutSeconds
    guard seconds >= 1 else {
      throw VMLabError.invalidRequest(
        field: "timeoutSeconds", reason: "timeoutSeconds must be at least 1",
        hint: "Pass a positive number of seconds.")
    }
    let viaName = try arguments.string("via") ?? "auto"
    guard let via = ExecVia(rawValue: viaName) else {
      throw VMLabError.invalidRequest(
        field: "via", reason: "via must be auto, ssh or agent", hint: "Pick auto, ssh or agent.")
    }
    var env: [String: String] = [:]
    if let value = arguments["env"] {
      guard let object = value.objectValue else { throw ToolArguments.mismatch("env", "an object") }
      for (name, value) in object {
        guard RemoteShell.isValidEnvironmentName(name) else {
          throw VMLabError.invalidRequest(
            field: "env", reason: "\(name) is not a valid environment variable name",
            hint: "Use names of letters, digits and underscores, not starting with a digit.")
        }
        guard let string = value.stringValue else {
          throw ToolArguments.mismatch("env.\(name)", "a string")
        }
        env[name] = string
      }
    }
    let user = try arguments.string("user")
    if let user, user.isEmpty {
      throw VMLabError.invalidRequest(
        field: "user", reason: "user must not be empty", hint: "Omit user to run as the login user."
      )
    }
    return ExecRequest(
      command: command, stdin: try arguments.string("stdin").map { Data($0.utf8) },
      timeout: .seconds(seconds), cwd: try arguments.string("cwd"), env: env, user: user,
      via: via)
  }

  /// The channel `via` names, refused with `capability_missing` when the plan did not grant it.
  static func channel(of vm: any RunningVM, via: ExecVia) throws(VMLabError) -> any ExecChannel {
    switch via {
    case .ssh: return try vm.channel(.execSSH)
    case .agent: return try vm.channel(.execAgent)
    case .auto:
      return vm.features.contains(.execSSH) ? try vm.channel(.execSSH) : try vm.channel(.exec)
    }
  }
}
