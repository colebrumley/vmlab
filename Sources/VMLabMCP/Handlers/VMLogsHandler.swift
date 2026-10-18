import Foundation
import VMLabCore

/// `vm_logs`: a VM's logs read from its directory, so it works on a stopped VM. `events` renders
/// `events.jsonl` one event per line (timestamp, level, kind, message, then any data as JSON);
/// `serial` and `provision` are the tails of `serial.log` and `provision.log`. Lines carry no
/// common clock, so `all` is each source's tail in turn, every line prefixed with its source.
struct VMLogsHandler: ToolHandler {
  static let defaultTail = 100
  static let maxTail = 10_000
  /// How much of the end of a text log is read to find its last lines.
  static let tailWindowBytes = 1 << 20

  var spec: ToolSpec { .vmLogs }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let record = try context.store.find(try arguments.string("vm") ?? "")
    let source = try arguments.string("source") ?? "all"
    guard ["events", "serial", "provision", "all"].contains(source) else {
      throw VMLabError.invalidRequest(
        field: "source", reason: "source must be events, serial, provision or all",
        hint: "Pick one of events, serial, provision, all.")
    }
    let tail = try arguments.int("tail") ?? Self.defaultTail
    guard (1...Self.maxTail).contains(tail) else {
      throw VMLabError.invalidRequest(
        field: "tail", reason: "tail must be between 1 and \(Self.maxTail)",
        hint: "Ask for at most \(Self.maxTail) lines.")
    }
    let directory = context.store.directory(of: record.id)
    var warnings: [String] = []
    var lines: [String] = []
    let prefix = source == "all"
    if source == "events" || prefix {
      let events = await Self.eventLines(directory, tail: tail, warnings: &warnings)
      lines += events.map { prefix ? "[events] \($0)" : $0 }
    }
    for name in ["serial", "provision"] where source == name || prefix {
      let file = directory.appending(path: "\(name).log")
      let text = Self.tailLines(of: file, count: tail, warnings: &warnings)
      lines += text.map { prefix ? "[\(name)] \($0)" : $0 }
    }
    return ToolResult(["lines": .array(lines.map { .string($0) })], warnings: warnings)
  }

  static func eventLines(_ directory: URL, tail: Int, warnings: inout [String]) async -> [String] {
    do {
      let contents = try await EventLog(vmDirectory: directory).read()
      if !contents.skippedLines.isEmpty {
        warnings.append(
          "events.jsonl has \(contents.skippedLines.count) malformed line(s), skipped")
      }
      return contents.events.suffix(tail).map(render)
    } catch {
      warnings.append("events.jsonl could not be read: \(error)")
      return []
    }
  }

  /// `ts level kind: message`, then the event's data as compact JSON when it has any.
  static func render(_ event: VMEvent) -> String {
    let ts = event.ts.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    var line = "\(ts) \(event.level.rawValue) \(event.kind.rawValue): \(event.message)"
    if let data = event.data, !data.isEmpty {
      line += " " + ToolRendering.json(.object(data))
    }
    return line
  }

  /// The last `count` lines of a text file, read from at most its last `tailWindowBytes`. A
  /// missing file has no lines.
  static func tailLines(of url: URL, count: Int, warnings: inout [String]) -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      let start = size > UInt64(tailWindowBytes) ? size - UInt64(tailWindowBytes) : 0
      try handle.seek(toOffset: start)
      let data = try handle.readToEnd() ?? Data()
      // Split on bytes: a String would keep "\r\n" together as one character.
      var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map {
        line in
        String(decoding: line.last == UInt8(ascii: "\r") ? line.dropLast() : line, as: UTF8.self)
      }
      if start > 0, !lines.isEmpty { lines.removeFirst() }
      if lines.last == "" { lines.removeLast() }
      return Array(lines.suffix(count))
    } catch {
      warnings.append("\(url.lastPathComponent) could not be read: \(error)")
      return []
    }
  }
}
