import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab images pull|list|remove`: the `images` tool's handler, one subcommand per action.
struct Images: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "images",
    abstract: "Pull, list and remove guest images (the images tool).",
    subcommands: [Pull.self, List.self, Remove.self]
  )

  struct Pull: ToolCommand {
    static let configuration = CommandConfiguration(
      abstract: "Download an image, verify its checksum and record it (a no-op when current).")
    static let toolName = "images"

    @Argument(help: "The image name, from `vmlab images list`.") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      .object(["action": .string("pull"), "name": .string(name)])
    }

    func render(_ result: ToolResult) -> String {
      let v = result.value
      let files = Human.list(v["files"])
      return v["cached"]?.boolValue == true
        ? "\(name) is already pulled and current (\(files))"
        : "Pulled \(name) into \(v["path"]?.stringValue ?? "?") (\(files))"
    }
  }

  struct List: ToolCommand {
    static let configuration = CommandConfiguration(abstract: "Show pulled and available images.")
    static let toolName = "images"

    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue { .object(["action": .string("list")]) }

    func render(_ result: ToolResult) -> String {
      (result.value["images"]?.arrayValue ?? []).map { row in
        let guest = "\(row["guest"]?.stringValue ?? "?")/\(row["arch"]?.stringValue ?? "?")"
        let state =
          row["pulled"]?.boolValue == true
          ? "pulled \(row["pulledAt"]?.stringValue ?? "")" : "available"
        return Human.pad(row["name"]?.stringValue ?? "?", 20) + Human.pad(guest, 14)
          + Human.pad(row["format"]?.stringValue ?? "", 7) + state
      }.joined(separator: "\n")
    }
  }

  struct Remove: ToolCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a pulled image.")
    static let toolName = "images"

    @Argument(help: "The image name.") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      .object(["action": .string("remove"), "name": .string(name)])
    }

    func render(_ result: ToolResult) -> String {
      Human.strings(result.value["removed"]).isEmpty ? "\(name) was not pulled" : "Removed \(name)"
    }
  }
}
