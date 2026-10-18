import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab images pull|list|remove|register|extract-kernel`: the `images` tool's handler, one
/// subcommand per action.
struct Images: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "images",
    abstract: "Pull, list and remove guest images (the images tool).",
    subcommands: [Pull.self, List.self, Remove.self, Register.self, ExtractKernel.self]
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
      abstract: "Register a local disk image, a macOS IPSW or a kernel under an image name.",
      discussion: """
        vmlab images register <name> --disk <path> --guest linux --arch arm64 [--format raw|qcow2]
        vmlab images register [<name>] --ipsw <path>     (tart create --from-ipsw; see docs/AGENT.md)
        vmlab images register <name> --kernel <path> [--initrd <path>] [--arch arm64]
        """)
    static let toolName = "images"

    @Argument(help: "The image name to register under (default for --ipsw: macos-ipsw).")
    var name: String?
    @Option(help: "Host path of a raw or qcow2 Linux disk image.") var disk: String?
    @Option(help: "Host path of a macOS restore image (.ipsw) for Apple silicon.") var ipsw: String?
    @Option(help: "Host path of the kernel image.") var kernel: String?
    @Option(help: "Host path of its initrd.") var initrd: String?
    @Option(help: "The disk's guest OS.") var guest = "linux"
    @Option(help: "The image's architecture (arm64, x86_64, ...).") var arch = "arm64"
    @Option(help: "The disk's format (raw or qcow2); default from its header.") var format: String?
    @Flag(help: "Print the result object as JSON.") var json = false

    func validate() throws {
      let given = [disk, ipsw, kernel].compactMap { $0 }
      guard given.count == 1 else {
        throw ValidationError("Give exactly one of --disk, --ipsw or --kernel.")
      }
      if ipsw == nil, name == nil { throw ValidationError("Give the image name.") }
    }

    func arguments() throws -> JSONValue {
      var object: [String: JSONValue] = ["action": .string("register")]
      if let name { object["name"] = .string(name) }
      if let kernel {
        object["kernel"] = .string(Images.absolute(kernel))
        object["arch"] = .string(arch)
        if let initrd { object["initrd"] = .string(Images.absolute(initrd)) }
      } else if let ipsw {
        object["path"] = .string(Images.absolute(ipsw))
      } else if let disk {
        object["path"] = .string(Images.absolute(disk))
        object["guest"] = .string(guest)
        object["arch"] = .string(arch)
        if let format { object["format"] = .string(format) }
      }
      return .object(object)
    }

    func render(_ result: ToolResult) -> String {
      if kernel != nil { return Images.renderKernel(result, "Registered") }
      let v = result.value
      var text =
        "Registered \(v["name"]?.stringValue ?? "?") (\(v["guest"]?.stringValue ?? "?")/"
        + "\(v["arch"]?.stringValue ?? "?"), \(v["format"]?.stringValue ?? "?")) in "
        + "\(v["path"]?.stringValue ?? "?")"
      for warning in result.warnings { text += "\nwarning: \(warning)" }
      return text
    }
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

  /// A path given on the command line, made absolute against the working directory.
  static func absolute(_ path: String) -> String {
    URL(filePath: path, relativeTo: URL.currentDirectory()).standardizedFileURL.path
  }
}
