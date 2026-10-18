import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab computer <vm> <action>`: the `vm_computer` tool. The image of a screenshot (and of every
/// acting action) is written to `--out` when given. Each run is its own process, so `--diff-from`
/// and `--scaled` only see screenshots taken within it.
struct ComputerCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "computer",
    abstract: "See and drive a VM's display (the vm_computer tool).")
  static let toolName = "vm_computer"

  @Argument(help: "The VM's id or name.") var vm: String
  @Argument(help: "screenshot, left_click, type, key, scroll, zoom, screen_info, ...")
  var action: String
  @Option(help: "x,y: the click, move or scroll point; the drag's end.") var at: String?
  @Option(help: "x,y: where a left_click_drag starts.") var from: String?
  @Option(help: "type: the text; key: the key or chord, e.g. ctrl+alt+t.") var text: String?
  @Option(help: "scroll: up, down, left or right.") var direction: String?
  @Option(help: "scroll: wheel clicks.") var amount: Int?
  @Option(help: "x0,y0,x1,y1: screenshot or zoom only this rectangle.") var region: String?
  @Option(help: "wait: seconds.") var seconds: Double?
  @Option(help: "Longest edge of the image.") var maxEdge: Int?
  @Option(help: "png or jpeg.") var format: String?
  @Option(help: "Delay in ms before the screenshot after an action.") var settleMs: Int?
  @Option(help: "Write the returned image to this file.") var out: String?
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = ["vm": .string(vm), "action": .string(action)]
    if let at { object["coordinate"] = try Self.numbers(at, count: 2, name: "--at") }
    if let from { object["startCoordinate"] = try Self.numbers(from, count: 2, name: "--from") }
    if let region { object["region"] = try Self.numbers(region, count: 4, name: "--region") }
    if let text { object["text"] = .string(text) }
    if let direction { object["scrollDirection"] = .string(direction) }
    if let amount { object["scrollAmount"] = .number(Double(amount)) }
    if let seconds { object["durationSeconds"] = .number(seconds) }
    if let maxEdge { object["maxEdge"] = .number(Double(maxEdge)) }
    if let format { object["format"] = .string(format) }
    if let settleMs { object["settleMs"] = .number(Double(settleMs)) }
    return .object(object)
  }

  func run() async throws {
    let result = try await ToolHandlers.call(
      Self.toolName, arguments: try arguments(), context: .live())
    if let out, let image = result.images.first {
      try image.data.write(to: URL(filePath: out))
    }
    if json {
      print(ToolRendering.json(result.value, pretty: true))
    } else {
      print(render(result))
      for warning in result.warnings {
        FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
      }
    }
  }

  func render(_ result: ToolResult) -> String {
    let v = result.value
    if action == "cursor_position" { return "\(Human.int(v["x"])),\(Human.int(v["y"]))" }
    var line = "\(Human.int(v["width"]))x\(Human.int(v["height"]))"
    if let id = v["id"]?.stringValue {
      line = "\(id) " + line + " scale \(v["scale"]?.numberValue ?? 1)"
      if v["unchanged"] == .bool(true) { line += " unchanged" }
      if let out, !result.images.isEmpty { line += " -> \(out)" }
    }
    return line
  }

  static func numbers(_ text: String, count: Int, name: String) throws -> JSONValue {
    let parts = text.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == count, parts.allSatisfy({ $0 != nil }) else {
      throw ValidationError("\(name) takes \(count) comma-separated integers")
    }
    return .array(parts.map { .number(Double($0!)) })
  }
}
