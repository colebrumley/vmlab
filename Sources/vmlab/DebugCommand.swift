import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab debug <vm> <action>`: the `vm_debug` tool. Each invocation is its own process, so it
/// attaches, acts and lets the connection go; `vmlab serve` keeps one across calls.
struct DebugCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "debug",
    abstract: "Debug the guest CPU through its GDB stub (the vm_debug tool).",
    discussion: "Actions: info, halt, continue, step, wait, breakpoint_add, breakpoint_remove, "
      + "breakpoints, registers, read_memory, write_memory.")
  static let toolName = "vm_debug"

  @Argument(help: "The VM's id or name.") var vm: String
  @Argument(help: "What to do.") var action: String
  @Option(help: "Guest address in 0x hex.") var address: String?
  @Option(help: "read_memory: bytes to read; watchpoints: bytes to watch.") var size: Int?
  @Option(help: "write_memory: the bytes as hex.") var data: String?
  @Option(help: "software, hardware, watch_write, watch_read or watch_access.") var kind: String?
  @Option(name: .customLong("timeout"), help: "wait: the longest to block, in seconds.")
  var timeoutSeconds: Int?
  @Option(help: "The thread (CPU) to act on.") var thread: String?
  @Option(help: "A symbol file to record for info.") var symbolFile: String?
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = ["vm": .string(vm), "action": .string(action)]
    if let address { object["address"] = .string(address) }
    if let size { object["size"] = .number(Double(size)) }
    if let data { object["data"] = .string(data) }
    if let kind { object["kind"] = .string(kind) }
    if let timeoutSeconds { object["timeoutSeconds"] = .number(Double(timeoutSeconds)) }
    if let thread { object["thread"] = .string(thread) }
    if let symbolFile { object["symbolFile"] = .string(symbolFile) }
    return .object(object)
  }

  func render(_ result: ToolResult) -> String {
    let v = result.value
    var lines: [String] = []
    if let reason = v["reason"]?.stringValue {
      lines.append("stopped (\(reason)) at \(v["pc"]?.stringValue ?? "?")")
    } else if v["stopped"]?.boolValue == false {
      lines.append("running")
    }
    if let registers = v["registers"]?.objectValue {
      for name in registers.keys.sorted() {
        lines.append(Human.pad(name, 8) + (registers[name]?.stringValue ?? "unavailable"))
      }
    }
    if let bytes = v["bytes"]?.stringValue {
      lines.append("\(v["address"]?.stringValue ?? "?"): \(bytes)")
      if let ascii = v["ascii"]?.stringValue { lines.append("ascii: \(ascii)") }
    }
    if let points = v["breakpoints"]?.arrayValue, action.hasPrefix("breakpoint") || action == "info"
    {
      lines.append(points.isEmpty ? "no breakpoints" : "breakpoints:")
      for point in points {
        let size = point["size"]?.numberValue.map { " (\(Int($0)) bytes)" } ?? ""
        lines.append(
          "  \(point["address"]?.stringValue ?? "?") \(point["kind"]?.stringValue ?? "")\(size)")
      }
    }
    if action == "info" {
      lines.append(
        "endpoint \(v["endpoint"]?.stringValue ?? "?"), attached: "
          + (v["attached"]?.boolValue == true ? "yes" : "no"))
      if let gdb = v["connect"]?["gdb"]?.stringValue { lines.append("gdb:  \(gdb)") }
      if let lldb = v["connect"]?["lldb"]?.stringValue { lines.append("lldb: \(lldb)") }
    }
    return lines.joined(separator: "\n")
  }
}
