import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab gc` (R-805): the garbage collector over `VMLAB_HOME`. Not an MCP tool: it is the
/// operator's broom, and what it removes is never something a model asked to keep.
struct GCCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gc",
    abstract:
      "Remove orphaned engine processes, old dumps and exec logs, temporary checkpoints and "
      + "unused backing files; report the bytes freed.")

  @Flag(help: "Report what would be removed without removing it.") var dryRun = false
  @Flag(help: "Print the report as JSON.") var json = false

  func run() async throws {
    var collector = GarbageCollector(manager: ToolContext.live().manager)
    collector.dryRun = dryRun
    let report = await collector.run()
    if json {
      var object = try JSONValue(encoding: report).objectValue ?? [:]
      object["bytesFreed"] = .number(Double(report.bytesFreed))
      print(ToolRendering.json(.object(object), pretty: true))
    } else {
      print(Self.render(report))
    }
    for error in report.errors {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    }
  }

  static func render(_ report: GCReport) -> String {
    var lines = report.items.map {
      "\(Human.pad($0.kind.rawValue, 21))\(Human.pad(bytes($0.bytes), 10))\($0.target)"
    }
    let verb = report.dryRun ? "would free" : "freed"
    lines.append("\(report.items.count) item(s), \(verb) \(bytes(report.bytesFreed))")
    return lines.joined(separator: "\n")
  }

  static func bytes(_ count: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }
}
