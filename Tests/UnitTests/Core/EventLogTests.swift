import Foundation
import Testing
import VMLabCore

@Suite struct EventLogTests {
  static func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-events-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func hundredEventsRoundTrip() async throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = EventLog(vmDirectory: dir)
    let kinds = VMEvent.Kind.allCases
    let start = Date(timeIntervalSince1970: 1_800_000_000.125)
    let written = (0..<100).map { i in
      VMEvent(
        ts: start.addingTimeInterval(Double(i) * 0.5),
        level: i % 7 == 0 ? .error : .info,
        kind: kinds[i % kinds.count],
        message: "event \(i) with \"quotes\", a / and a\nnewline")
    }
    for event in written { try await log.append(event) }

    let contents = try await log.read()
    #expect(contents.skippedLines.isEmpty)
    #expect(contents.events == written)
    let text = try String(contentsOf: log.url, encoding: .utf8)
    #expect(text.split(separator: "\n").count == 100)
  }

  @Test func malformedLineIsSkipped() async throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = EventLog(vmDirectory: dir)
    try await log.append(.lifecycle, "started")
    let handle = try FileHandle(forWritingTo: log.url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{not json\n\n{\"kind\":\"bogus\"}\n".utf8))
    try handle.close()
    try await log.append(.panic, "Kernel panic", level: .critical)

    let contents = try await log.read()
    #expect(contents.events.map(\.kind) == [.lifecycle, .panic])
    #expect(contents.events.last?.level == .critical)
    #expect(contents.skippedLines == [2, 4])
  }

  @Test func missingFileIsEmpty() async throws {
    let log = EventLog(vmDirectory: try Self.tempDirectory())
    #expect(try await log.read() == EventLogContents(events: [], skippedLines: []))
  }

  @Test func lineHasTheDocumentedFields() throws {
    let line = #"{"kind":"net","level":"warning","message":"m","ts":"2026-10-17T12:00:00.250Z"}"#
    let contents = EventLog.parse(Data(line.utf8))
    #expect(contents.events.count == 1)
    #expect(contents.events.first?.kind == .net)
    #expect(contents.events.first?.level == .warning)
  }
}
