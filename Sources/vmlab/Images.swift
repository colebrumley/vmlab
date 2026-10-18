import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab images pull|list|remove|register|extract-kernel|template create`: the `images` tool's handler, one
/// subcommand per action.
struct Images: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "images",
    abstract: "Pull, list and remove guest images (the images tool).",
    subcommands: [
      Pull.self, List.self, Remove.self, Register.self, ExtractKernel.self, Template.self,
    ]
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

  static func renderKernel(_ result: ToolResult, _ verb: String) -> String {
    let v = result.value
    let version = v["version"]?.stringValue.map { " (\($0))" } ?? ""
    return "\(verb) the kernel of \(v["name"]?.stringValue ?? "?")\(version) into "
      + "\(v["path"]?.stringValue ?? "?"): \(Human.list(v["files"]))"
  }

  struct Register: ToolCommand {
    static let configuration = CommandConfiguration(
      abstract: "Register a kernel (and initrd) under an image name for direct kernel boot.")
    static let toolName = "images"

    @Argument(help: "The image name to register under.") var name: String
    @Option(help: "Host path of the kernel image.") var kernel: String
    @Option(help: "Host path of its initrd.") var initrd: String?
    @Option(help: "The kernel's architecture (arm64, x86_64, ...).") var arch = "arm64"
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      var object: [String: JSONValue] = [
        "action": .string("register"), "name": .string(name),
        "kernel": .string(Images.absolute(kernel)), "arch": .string(arch),
      ]
      if let initrd { object["initrd"] = .string(Images.absolute(initrd)) }
      return .object(object)
    }

    func render(_ result: ToolResult) -> String { Images.renderKernel(result, "Registered") }
  }

  struct ExtractKernel: ToolCommand {
    static let configuration = CommandConfiguration(
      commandName: "extract-kernel",
      abstract: "Copy the kernel, initrd, System.map and config out of a pulled Linux image.")
    static let toolName = "images"

    @Argument(help: "The pulled image's name.") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func arguments() throws -> JSONValue {
      .object(["action": .string("extract_kernel"), "name": .string(name)])
    }

    func render(_ result: ToolResult) -> String { Images.renderKernel(result, "Extracted") }
  }

  /// `vmlab images template create <vm> <name>` (R-804).
  struct Template: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Make templates from stopped VMs.", subcommands: [Create.self])

    struct Create: ToolCommand {
      static let configuration = CommandConfiguration(
        abstract: "Copy a stopped VM's disk into a template image for vm_create and fleets.")
      static let toolName = "images"

      @Argument(help: "The stopped VM (name or id).") var vm: String
      @Argument(help: "The template's image name.") var name: String
      @Flag(help: "Print the result object as JSON.") var json = false

      func arguments() throws -> JSONValue {
        .object([
          "action": .string("template_create"), "vm": .string(vm), "name": .string(name),
        ])
      }

      func render(_ result: ToolResult) -> String {
        "Made template \(name) from \(vm) in \(result.value["path"]?.stringValue ?? "?")"
      }
    }
  }

  /// A path given on the command line, made absolute against the working directory.
  static func absolute(_ path: String) -> String {
    URL(filePath: path, relativeTo: URL.currentDirectory()).standardizedFileURL.path
  }
}
