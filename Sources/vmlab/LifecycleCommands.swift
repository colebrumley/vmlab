import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

// MARK: create

/// `vmlab create`: the `vm_create` tool, with the requirement flags of `vmlab plan`.
struct CreateCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a VM from requirements and start it (the vm_create tool).")
  static let toolName = "vm_create"

  @OptionGroup var request: PlanCommand
  @Option(help: "A unique name for the VM; defaults to its id.") var name: String?
  @Flag(name: .customLong("no-start"), help: "Create the VM but do not start it.")
  var noStart = false

  var json: Bool { request.json }

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = ["requirements": try request.requirementsValue()]
    if let name { object["name"] = .string(name) }
    if noStart { object["autostart"] = .bool(false) }
    if request.allowUnverified { object["allowUnverified"] = .bool(true) }
    return .object(object)
  }

  func render(_ result: ToolResult) -> String {
    let v = result.value
    var lines = [
      "\(v["vm"]?["id"]?.stringValue ?? "?") \(v["vm"]?["name"]?.stringValue ?? ""): "
        + "\(v["state"]?.stringValue ?? "?") on \(v["plan"]?["profile"]?.stringValue ?? "?")",
      "features: \(Human.list(v["plan"]?["features"]))",
    ]
    let endpoints = v["endpoints"]?.objectValue ?? [:]
    for key in endpoints.keys.sorted() {
      guard let value = endpoints[key] else { continue }
      lines.append("\(key): \(value.stringValue ?? value["hostSide"]?.stringValue ?? "")")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: lifecycle

/// One `vm_lifecycle` action as a subcommand: `vmlab start web`.
protocol LifecycleCommand: ToolCommand {
  static var action: String { get }
  var vm: String { get }
  var extra: [String: JSONValue] { get }
}

extension LifecycleCommand {
  static var toolName: String { "vm_lifecycle" }
  var extra: [String: JSONValue] { [:] }

  func arguments() throws -> JSONValue {
    .object(extra.merging(["vm": .string(vm), "action": .string(Self.action)]) { $1 })
  }

  func render(_ result: ToolResult) -> String {
    let v = result.value
    return "\(v["vm"]?["id"]?.stringValue ?? vm) \(v["vm"]?["name"]?.stringValue ?? ""): "
      + "\(v["state"]?.stringValue ?? "?") (\(Human.int(v["durationMs"])) ms)"
  }
}

struct StartCommand: LifecycleCommand {
  static let configuration = CommandConfiguration(
    commandName: "start", abstract: "Boot a VM (vm_lifecycle start).")
  static let action = "start"
  @Argument(help: "The VM's id or name.") var vm: String
  @Flag(help: "Print the result object as JSON.") var json = false
}

struct StopCommand: LifecycleCommand {
  static let configuration = CommandConfiguration(
    commandName: "stop", abstract: "Shut a VM down gracefully (vm_lifecycle stop).")
  static let action = "stop"
  @Argument(help: "The VM's id or name.") var vm: String
  @Flag(help: "Print the result object as JSON.") var json = false
}

struct KillCommand: LifecycleCommand {
  static let configuration = CommandConfiguration(
    commandName: "kill", abstract: "Stop a VM at once (vm_lifecycle kill).")
  static let action = "kill"
  @Argument(help: "The VM's id or name.") var vm: String
  @Flag(help: "Print the result object as JSON.") var json = false
}

struct PauseCommand: LifecycleCommand {
  static let configuration = CommandConfiguration(
    commandName: "pause", abstract: "Freeze a VM in memory (vm_lifecycle pause).")
  static let action = "pause"
  @Argument(help: "The VM's id or name.") var vm: String
  @Flag(help: "Print the result object as JSON.") var json = false
}

struct ResumeCommand: LifecycleCommand {
  static let configuration = CommandConfiguration(
    commandName: "resume", abstract: "Thaw a paused VM (vm_lifecycle resume).")
  static let action = "resume"
  @Argument(help: "The VM's id or name.") var vm: String
  @Flag(help: "Print the result object as JSON.") var json = false
}

struct ResetCommand: LifecycleCommand {
  static let configuration = CommandConfiguration(
    commandName: "reset", abstract: "Reset a VM's CPU (vm_lifecycle reset).")
  static let action = "reset"
  @Argument(help: "The VM's id or name.") var vm: String
  @Flag(help: "Print the result object as JSON.") var json = false
}

struct DestroyCommand: LifecycleCommand {
  static let configuration = CommandConfiguration(
    commandName: "destroy", abstract: "Delete a VM and its disk (vm_lifecycle destroy).")
  static let action = "destroy"
  @Argument(help: "The VM's id or name.") var vm: String
  @Flag(help: "Even when another VM's disk depends on this one.") var force = false
  @Flag(help: "Print the result object as JSON.") var json = false

  var extra: [String: JSONValue] { force ? ["force": .bool(true)] : [:] }
}
