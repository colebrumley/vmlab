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
