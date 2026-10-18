import Foundation
import Logging

/// One line of a VM's `events.jsonl`.
public struct VMEvent: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case lifecycle, serial, checkpoint, net, error, panic
  }

  public var ts: Date
  public var level: Logger.Level
  public var kind: Kind
  public var message: String
  /// Structured detail, absent on most events: a panic's `pattern` and serial `offset`, a QMP
  /// event's `data`.
  public var data: [String: JSONValue]?

  public init(
    ts: Date = Date(), level: Logger.Level = .info, kind: Kind, message: String,
    data: [String: JSONValue]? = nil
  ) {
    self.ts = ts
    self.level = level
    self.kind = kind
    self.message = message
    self.data = data
  }
}

/// What a read of `events.jsonl` found: the events in file order, and the 1-based numbers of the
/// lines that were not events and were skipped.
public struct EventLogContents: Sendable, Equatable {
  public var events: [VMEvent]
  public var skippedLines: [Int]

  public init(events: [VMEvent], skippedLines: [Int]) {
    self.events = events
    self.skippedLines = skippedLines
  }
}

/// The append-only event log in a VM directory. Core owns the format; backends append through it.
/// Each event is one `write(2)` on a descriptor opened with `O_APPEND`, so lines from the server
/// and from a runner process never interleave.
public actor EventLog {
  public static let fileName = "events.jsonl"

  public nonisolated let url: URL
  private let logger: Logger

  public init(vmDirectory: URL, logger: Logger = Logger(label: "vmlab.events")) {
    self.url = vmDirectory.appending(path: Self.fileName)
    self.logger = logger
  }

  public func append(_ event: VMEvent) throws {
    var line = try Self.encoder.encode(event)
    line.append(UInt8(ascii: "\n"))
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard written == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  public func append(_ kind: VMEvent.Kind, _ message: String, level: Logger.Level = .info) throws {
    try append(VMEvent(level: level, kind: kind, message: message))
  }

  /// Every event in the file; a missing file is an empty log. A line that does not decode is
  /// skipped with a warning.
  public func read() throws -> EventLogContents {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return EventLogContents(events: [], skippedLines: [])
    }
    let contents = Self.parse(try Data(contentsOf: url))
    for number in contents.skippedLines {
      logger.warning(
        "skipped malformed event line", metadata: ["file": "\(url.path)", "line": "\(number)"])
    }
    return contents
  }

  /// Decodes `events.jsonl` content; blank lines are ignored, undecodable ones reported.
  public static func parse(_ data: Data) -> EventLogContents {
    var events: [VMEvent] = []
    var skipped: [Int] = []
    for (index, line) in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
      .enumerated()
    {
      if line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) { continue }
      if let event = try? decoder.decode(VMEvent.self, from: Data(line)) {
        events.append(event)
      } else {
        skipped.append(index + 1)
      }
    }
    return EventLogContents(events: events, skippedLines: skipped)
  }

  private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(timestampStyle))
    }
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      return try timestampStyle.parse(text)
    }
    return decoder
  }()
}
