import Foundation
import Testing

@testable import VMLabCore

/// A channel backed by the engine's durable console log: offsets are byte offsets into
/// `console.log`, so they mean the same in every process (a CLI call, the MCP server, a restart),
/// and output the guest printed while no process held the socket is there to read and wait on.
@Suite struct SerialConsoleLogTests {
  /// The engine's side: appends guest output to the console log, as QEMU's chardev `logfile` and
  /// the VZ runner do whether or not anyone holds the socket.
  func guestPrints(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }

  func consoleURL(_ server: FakeSerialServer) -> URL {
    let url = server.directory.appending(path: "console.log")
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    return url
  }

  func channel(
    _ server: FakeSerialServer, ringCapacity: Int = SerialChannel.defaultRingCapacity
  ) async throws -> SerialChannel {
    let channel = SerialChannel(
      socketPath: server.path, logURL: server.logURL, ringCapacity: ringCapacity,
      consoleLog: consoleURL(server))
    try await channel.start()
    await server.accept()
    return channel
  }

  @Test func outputLoggedBeforeTheChannelStartedIsReadableAtLogOffsets() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    try guestPrints("boot ok\ndebian login: ", to: consoleURL(server))
    let channel = try await channel(server)
    #expect(await channel.endOffset == 22)
    #expect(await channel.startOffset == 0)
    let all = await channel.read(since: 0)
    #expect(
      all == SerialRead(text: "boot ok\ndebian login: ", start: 0, offset: 22, truncated: false))
    #expect(await channel.read(tail: 1).text == "debian login: ")
    let match = try await channel.wait(for: "login:", since: 0, timeout: .seconds(5))
    #expect(match == SerialMatch(match: "login:", start: 15, offset: 21))
    // The socket's own bytes are not the record; the log is.
    #expect(!FileManager.default.fileExists(atPath: server.logURL.path))
    await channel.stop()
  }

  @Test func offsetsCarryOverBetweenChannelsLikeSeparateCLICalls() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let console = consoleURL(server)
    try guestPrints("boot ok\n", to: console)

    // `vmlab serial vm write '\n'`: one process, one channel, then gone.
    let first = try await channel(server)
    let mark = try await first.write("\n")
    #expect(mark == 8)
    #expect(await server.receive(1) == "\n")
    await first.stop()
    server.closePeer()

    // The guest answers while nobody holds the socket; the engine logs it.
    try guestPrints("\ndebian login: ", to: console)

    // `vmlab serial vm wait login: --since 8`: a new process sees the prompt.
    let second = try await channel(server)
    let match = try await second.wait(for: "login:", since: mark, timeout: .seconds(5))
    #expect(match.offset == 22)
    #expect(await second.read(tail: 1).text == "debian login: ")
    await second.stop()
  }

  @Test func newOutputIsFollowedFromTheLog() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let console = consoleURL(server)
    try guestPrints("old\n", to: console)
    let channel = try await channel(server)
    let since = await channel.endOffset
    async let match = channel.wait(for: "ready", since: since, timeout: .seconds(5))
    try await Task.sleep(for: .milliseconds(50))
    try guestPrints("not yet\nready\n", to: console)
    // The socket carries the same bytes; they only wake the channel.
    await server.send("not yet\nready\n")
    let found = try await match
    #expect(found == SerialMatch(match: "ready", start: 12, offset: 17))
    #expect(await eventually { await channel.endOffset == 18 })
    await channel.stop()
  }

  @Test func readsOlderThanTheRingComeFromTheLog() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    try guestPrints("0123456789abcdef", to: consoleURL(server))
    let channel = try await channel(server, ringCapacity: 8)
    let read = await channel.read(since: 2)
    #expect(read == SerialRead(text: "23456789abcdef", start: 2, offset: 16, truncated: false))
    let match = try await channel.wait(for: "345", since: 0, timeout: .seconds(5))
    #expect(match.start == 3)
    await channel.stop()
  }

  @Test func panicWatchScansTheLogOnceAndThenLiveLines() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let console = consoleURL(server)
    try guestPrints("hello\nKernel panic - not syncing: early\n", to: console)
    let channel = SerialChannel(
      socketPath: server.path, logURL: server.logURL, consoleLog: console)
    let watch = ConsolePanicWatch(vmDirectory: server.directory, console: console)
    await watch.attach(to: channel)
    try await channel.start()
    await server.accept()
    try guestPrints("Kernel panic - not syncing: late\n", to: console)
    let log = EventLog(vmDirectory: server.directory)
    #expect(
      await eventually {
        ((try? await log.read().events) ?? []).filter(EventLog.isPanic).count == 2
      })
    let panics = try await log.read().events.filter(EventLog.isPanic)
    // Event offsets are console.log offsets, the same as vm_serial's.
    #expect(panics.map { $0.data?["offset"] } == [.number(6), .number(40)])
    #expect(watch.savedPosition == 73)
    await channel.stop()
  }

  @Test func aRunStartsWhereTheLogEnded() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-run-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(ConsoleRun.start(vmDirectory: dir) == 0)
    ConsoleRun.markStart(vmDirectory: dir)
    #expect(ConsoleRun.start(vmDirectory: dir) == 0)
    try Data("first run\n".utf8).write(to: dir.appending(path: "console.log"))
    ConsoleRun.markStart(vmDirectory: dir)
    #expect(ConsoleRun.start(vmDirectory: dir) == 10)
  }
}
