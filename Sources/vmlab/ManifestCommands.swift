import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab manifest`: the vm_manifest tool.
struct ManifestCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "manifest",
    abstract: "Record what is in a running guest: files, packages, services, users, defaults "
      + "(the vm_manifest tool).")
  static let toolName = "vm_manifest"

  @Argument(help: "The VM's id or name.") var vm: String
  @Argument(help: "Guest directories or files to walk.") var paths: [String] = []
  @Option(help: "linux, macos or custom (default: the guest's OS).") var profile: String?
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = ["vm": .string(vm)]
    if let profile { object["profile"] = .string(profile) }
    if !paths.isEmpty { object["paths"] = .array(paths.map { .string($0) }) }
    return .object(object)
  }

  /// The id and path, then one count per section.
  func render(_ result: ToolResult) -> String {
    var lines = [
      "\(result.value["id"]?.stringValue ?? "?")  \(result.value["path"]?.stringValue ?? "")"
    ]
    let counts = result.value["counts"]?.objectValue ?? [:]
    for key in counts.keys.sorted() {
      lines.append("  \(Human.pad(key, 12))\(Human.int(counts[key]))")
    }
    return lines.joined(separator: "\n")
  }
}
