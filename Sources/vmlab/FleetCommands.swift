import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab segment create|list|destroy`: the `net_segment` tool (R-901).
struct SegmentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "segment", abstract: "Manage private segments (the net_segment tool).",
    subcommands: [Create.self, List.self, Destroy.self])

  static func render(_ value: JSONValue) -> String {
    let members = (value["members"]?.arrayValue ?? []).map {
      "\($0["vm"]?.stringValue ?? "?")=\($0["ip"]?.stringValue ?? "?")"
    }
    let running = value["running"]?.boolValue == true ? "running" : "stopped"
    return Human.pad(value["name"]?.stringValue ?? "?", 20)
      + Human.pad(value["subnet"]?.stringValue ?? "", 16) + Human.pad(running, 9)
      + (members.isEmpty ? "no members" : members.joined(separator: " "))
  }

  struct Create: ToolCommand {
    static let configuration = CommandConfiguration(
      abstract: "Make a segment with its own 10.n.0.0/24 subnet and start its switch.")
    static let toolName = "net_segment"

    @Argument(help: "The segment name ([a-z0-9-], at most 32 characters).") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      .object(["action": .string("create"), "name": .string(name)])
    }

    func render(_ result: ToolResult) -> String { SegmentCommand.render(result.value) }
  }

  struct List: ToolCommand {
    static let configuration = CommandConfiguration(abstract: "Show segments and their members.")
    static let toolName = "net_segment"

    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue { .object(["action": .string("list")]) }

    func render(_ result: ToolResult) -> String {
      let rows = (result.value["segments"]?.arrayValue ?? []).map(SegmentCommand.render)
      return rows.isEmpty ? "no segments" : rows.joined(separator: "\n")
    }
  }

  struct Destroy: ToolCommand {
    static let configuration = CommandConfiguration(
      abstract: "Stop a segment's switch and remove it (it must have no members).")
    static let toolName = "net_segment"

    @Argument(help: "The segment name.") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      .object(["action": .string("destroy"), "name": .string(name)])
    }

    func render(_ result: ToolResult) -> String { "Destroyed segment \(name)" }
  }
}

/// `vmlab fleet create|list|status|exec|destroy`: the `fleet` tool (R-903, R-904).
struct FleetCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fleet", abstract: "Run groups of identical VMs on a segment (the fleet tool).",
    subcommands: [Create.self, List.self, Status.self, Exec.self, Destroy.self])

  static func render(_ value: JSONValue) -> String {
    var lines = [
      "fleet \(value["name"]?.stringValue ?? "?") on segment \(value["segment"]?.stringValue ?? "?")"
        + (value["subnet"]?.stringValue.map { " (\($0))" } ?? "")
    ]
    for member in value["members"]?.arrayValue ?? [] {
      var line =
        "  " + Human.pad(member["vm"]?.stringValue ?? "?", 20)
        + Human.pad(member["state"]?.stringValue ?? "?", 10)
        + (member["ip"]?.stringValue ?? "-")
      if let error = member["error"]?["message"]?.stringValue { line += "  error: \(error)" }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }

  struct Create: ToolCommand {
    static let configuration = CommandConfiguration(
      abstract: "Create <name>-1..<count> from one plan, on one segment, and wait for SSH.")
    static let toolName = "fleet"

    @Argument(help: "The fleet name ([a-z0-9-], at most 28 characters).") var name: String
    @Option(help: "How many members.") var count: Int
    @Option(help: "Image or template the members boot.") var image: String?
    @Option(help: "Segment to join, or auto to make one named after the fleet.") var segment:
      String?
    @Option(help: "Guest operating system.") var guest = "linux"
    @Option(help: "Guest architecture.") var arch = "arm64"
    @Option(help: "Required features, comma-separated or repeated.") var require: [String] = []
    @Option(help: "Virtual CPUs per member.") var cpus: Int?
    @Option(name: .customLong("memory-gb"), help: "Memory per member in GB.") var memoryGB: Int?
    @Option(name: .customLong("disk-gb"), help: "Disk per member in GB.") var diskGB: Int?
    @Option(help: "The whole requirements object as JSON, instead of the flags above.")
    var requirements: String?
    @Option(name: .customLong("timeout"), help: "Seconds each member waits for SSH.")
    var timeoutSeconds: Int?
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      var object: [String: JSONValue] = [
        "action": .string("create"), "name": .string(name), "count": .number(Double(count)),
      ]
      if let requirements {
        do {
          object["requirements"] = try JSONDecoder().decode(
            JSONValue.self, from: Data(requirements.utf8))
        } catch {
          throw ValidationError("--requirements is not valid JSON: \(error)")
        }
      } else {
        var r: [String: JSONValue] = [
          "guest": .object(["os": .string(guest), "arch": .string(arch)])
        ]
        let required = splitList(require)
        if !required.isEmpty { r["require"] = .array(required.map { .string($0) }) }
        var resources: [String: JSONValue] = [:]
        if let cpus { resources["cpus"] = .number(Double(cpus)) }
        if let memoryGB { resources["memoryGB"] = .number(Double(memoryGB)) }
        if let diskGB { resources["diskGB"] = .number(Double(diskGB)) }
        if !resources.isEmpty { r["resources"] = .object(resources) }
        object["requirements"] = .object(r)
      }
      if let image { object["image"] = .string(image) }
      if let segment { object["segment"] = .string(segment) }
      if let timeoutSeconds { object["timeoutSeconds"] = .number(Double(timeoutSeconds)) }
      return .object(object)
    }

    func render(_ result: ToolResult) -> String { FleetCommand.render(result.value) }
  }

  struct List: ToolCommand {
    static let configuration = CommandConfiguration(abstract: "Show the fleets.")
    static let toolName = "fleet"

    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue { .object(["action": .string("list")]) }

    func render(_ result: ToolResult) -> String {
      let rows = (result.value["fleets"]?.arrayValue ?? []).map {
        Human.pad($0["name"]?.stringValue ?? "?", 20)
          + Human.pad($0["profile"]?.stringValue ?? "", 10) + Human.list($0["members"])
      }
      return rows.isEmpty ? "no fleets" : rows.joined(separator: "\n")
    }
  }

  struct Status: ToolCommand {
    static let configuration = CommandConfiguration(abstract: "Show each member of a fleet.")
    static let toolName = "fleet"

    @Argument(help: "The fleet name.") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      .object(["action": .string("status"), "name": .string(name)])
    }

    func render(_ result: ToolResult) -> String { FleetCommand.render(result.value) }
  }

  struct Exec: ToolCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run a command on every member (or --member ones) in parallel.")
    static let toolName = "fleet"

    @Argument(help: "The fleet name.") var name: String
    @Argument(help: "The command, run by each guest's shell.") var command: String
    @Option(name: .customLong("member"), help: "Only this member; repeatable.")
    var members: [String] = []
    @Option(name: .customLong("timeout"), help: "Seconds before each member's command is killed.")
    var timeoutSeconds: Int?
    @Option(help: "Run as this guest user (sudo).") var user: String?
    @Option(help: "Working directory in the guest.") var cwd: String?
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      var object: [String: JSONValue] = [
        "action": .string("exec"), "name": .string(name), "command": .string(command),
      ]
      if !members.isEmpty { object["members"] = .array(members.map { .string($0) }) }
      if let timeoutSeconds { object["timeoutSeconds"] = .number(Double(timeoutSeconds)) }
      if let user { object["user"] = .string(user) }
      if let cwd { object["cwd"] = .string(cwd) }
      return .object(object)
    }

    func render(_ result: ToolResult) -> String {
      let results = result.value["results"]?.objectValue ?? [:]
      return results.keys.sorted().map { member in
        let value = results[member] ?? .null
        if let error = value["error"]?["message"]?.stringValue {
          return "\(member): error: \(error)"
        }
        let code = Human.int(value["exitCode"])
        let out = (value["stdout"]?.stringValue ?? "").trimmingCharacters(in: .newlines)
        return "\(member) [\(code)]: \(out)"
      }.joined(separator: "\n")
    }
  }

  struct Destroy: ToolCommand {
    static let configuration = CommandConfiguration(
      abstract: "Destroy a fleet's VMs, its own segment and its record.")
    static let toolName = "fleet"

    @Argument(help: "The fleet name.") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      .object(["action": .string("destroy"), "name": .string(name)])
    }

    func render(_ result: ToolResult) -> String {
      "Destroyed \(name): \(Human.list(result.value["destroyed"]))"
    }
  }
}
