import Foundation
import Testing
import VMLabCore

@Suite struct PanicDetectorTests {
  static func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-test-panic-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static let transcript = """
    [    0.000000] Booting Linux on physical CPU 0x0000000000 [0x611f0221]
    [    1.234567] Run /init as init process
    [    2.000001] sysrq: Trigger a crash
    [    2.000002] Kernel panic - not syncing: sysrq triggered crash
    [    2.000003] CPU: 0 PID: 1 Comm: sh Not tainted 6.12.0 #1
    [    2.000004] ---[ end Kernel panic - not syncing: sysrq triggered crash ]---

    """

  @Test func tableMatchesEachSignature() {
    let lines = [
      "[ 1.0] Kernel panic - not syncing: VFS: Unable to mount root fs",
      "[ 1.0] BUG: kernel NULL pointer dereference, address: 0000000000000000",
      "[ 1.0] Internal error: Oops: 0000000096000004 [#1] SMP",
      "[ 1.0] general protection fault, probably for non-canonical address",
      "Synchronous Exception at 0x00000000BFE1C2A0",
      "[ 9.0] rcu: INFO: rcu_sched self-detected stall on CPU",
    ]
    for (line, signature) in zip(lines, PanicSignature.table) {
      #expect(PanicSignature.match(line) == signature)
    }
    #expect(PanicSignature.match("[ 1.0] Run /init as init process") == nil)
  }

  @Test func panicTranscriptOverSerialLogsAnEventWithLineAndOffset() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let channel = SerialChannel(socketPath: server.path, logURL: server.logURL)
    let detector = PanicDetector(vmDirectory: dir)
    await detector.attach(to: channel)
    try await channel.start()
    await server.accept()
    await server.send(Self.transcript)
    let length = UInt64(Self.transcript.utf8.count)
    #expect(await eventually { await channel.endOffset == length })
    await channel.stop()
    await detector.finish()

    let events = try await detector.log.read().events
    #expect(events.count == 2)
    let first = try #require(events.first)
    #expect(first.kind == .panic && first.level == .critical)
    #expect(
      first.message == "[    2.000002] Kernel panic - not syncing: sysrq triggered crash")
    let prefix = Self.transcript.components(separatedBy: "[    2.000002]")[0]
    #expect(first.data?["offset"] == .number(Double(prefix.utf8.count)))
    #expect(first.data?["pattern"] == .string("Kernel panic - not syncing"))
    #expect(first.data?["source"] == .string("serial"))
    let latest = try await detector.log.latestPanic()
    #expect(latest?.message.contains("end Kernel panic") == true)
  }

  @Test func floodIsCappedWithOneSuppressionNotice() async throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let detector = PanicDetector(log: EventLog(vmDirectory: dir), maxEvents: 3)
    for index in 0..<10 {
      detector.observe(
        SerialLine(
          text: "Synchronous Exception at \(index)", start: UInt64(index * 30),
          end: UInt64(index * 30 + 30)))
    }
    await detector.finish()
    let events = try await detector.log.read().events
    #expect(events.count == 4)
    #expect(events.last?.data?["suppressed"] == .bool(true))
    #expect(!EventLog.isPanic(events[3]))
    #expect(try await detector.log.latestPanic()?.message == "Synchronous Exception at 2")
  }

  @Test func qmpEventsBecomeLogEntries() async throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = EventLog(vmDirectory: dir)
    let panicData: JSONValue = .object([
      "action": .string("pause"), "info": .object(["type": .string("hyper-v")]),
    ])
    #expect(try await log.recordQMPEvent("GUEST_PANICKED", data: panicData))
    #expect(
      try await log.recordQMPEvent(
        "RESET", data: .object(["guest": .bool(true), "reason": .string("guest-reset")])))
    #expect(try await !log.recordQMPEvent("STOP", data: nil))
    let events = try await log.read().events
    #expect(events.count == 2)
    #expect(events[0].kind == .panic && events[0].level == .critical)
    #expect(events[0].message == "guest panicked (QMP GUEST_PANICKED, action pause)")
    #expect(events[0].data?["data"] == panicData)
    #expect(events[0].data?["event"] == .string("GUEST_PANICKED"))
    #expect(events[1].kind == .lifecycle)
    #expect(events[1].message == "guest reset (QMP RESET, by the guest, reason guest-reset)")
    #expect(try await log.latestPanic() == events[0])
  }

  @Test func eventsWithoutDataStillDecode() {
    let line =
      #"{"kind":"lifecycle","level":"info","message":"started","ts":"2026-10-18T12:00:00.000Z"}"#
    let contents = EventLog.parse(Data(line.utf8))
    #expect(contents.events.count == 1 && contents.events[0].data == nil)
  }
}

/// R-304 durable: panics QEMU logged to console.log while nobody held the serial socket.
@Suite struct ConsolePanicWatchTests {
  static func panics(_ dir: URL) async throws -> [VMEvent] {
    try await EventLog(vmDirectory: dir).read().events.filter { $0.kind == .panic }
  }

  @Test func catchUpFindsWhatNobodyWatchedOnceEach() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-console-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let console = dir.appending(path: "console.log")
    try Data("boot\r\n[ 9.1] Kernel panic - not syncing: one\nhalf a li".utf8).write(to: console)

    let first = ConsolePanicWatch(vmDirectory: dir, console: console)
    #expect(first.catchUp() == 45)  // up to the partial line
    await first.detector.finish()
    var found = try await Self.panics(dir)
    #expect(found.map(\.message) == ["[ 9.1] Kernel panic - not syncing: one"])
    #expect(found.first?.data?["offset"] == .number(6))

    // A later attach (server restart) sees only what is new, the partial line completed.
    let handle = try FileHandle(forWritingTo: console)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("ne\nOops: two\n".utf8))
    try handle.close()
    let second = ConsolePanicWatch(vmDirectory: dir, console: console)
    second.catchUp()
    second.catchUp()
    await second.detector.finish()
    found = try await Self.panics(dir)
    #expect(found.map(\.message) == ["[ 9.1] Kernel panic - not syncing: one", "Oops: two"])

    // The log was removed and restarted: scanning starts over.
    try Data("BUG: three\n".utf8).write(to: console)
    let third = ConsolePanicWatch(vmDirectory: dir, console: console)
    #expect(third.catchUp() == 11)
    await third.detector.finish()
    #expect(try await Self.panics(dir).last?.message == "BUG: three")
  }

  @Test func liveLinesAdvanceThePosition() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-console-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let console = dir.appending(path: "console.log")
    try Data("abc\n".utf8).write(to: console)
    let watch = ConsolePanicWatch(vmDirectory: dir, console: console)
    watch.catchUp()
    watch.checkpoint(channelOffset: 10)  // the channel read 10 more bytes, also in the log
    #expect(watch.savedPosition == 14)
  }
}
