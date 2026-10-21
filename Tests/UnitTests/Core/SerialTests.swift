import Foundation
import Testing
import VMLabSwitch

@testable import VMLabCore

/// A fake guest end: a listening unix stream socket in /tmp (paths must stay under 104 bytes)
/// that accepts the channel's one connection.
final class FakeSerialServer: @unchecked Sendable {
  let path: String
  let directory: URL
  private let listener: Int32
  private var peer: Int32 = -1

  init() throws {
    let id = UUID().uuidString.prefix(8)
    path = "/tmp/vmlab-ser-\(id).sock"
    directory = URL(fileURLWithPath: "/tmp/vmlab-ser-\(id)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    listener = try UnixSocket.make(SOCK_STREAM)
    try UnixSocket.bind(listener, path: path)
    #expect(listen(listener, 1) == 0)
  }

  /// Accepts the channel's connection (call after `start`, which has connected by then). Like
  /// `send` and `receive`, it blocks in a syscall, so it runs off the cooperative pool.
  func accept() async {
    let listener = listener
    peer = await OffPool.run { Darwin.accept(listener, nil, nil) }
    #expect(peer >= 0)
  }

  func send(_ text: String) async { await send(Array(text.utf8)) }

  /// Writes all of `bytes`; blocks while the channel's socket buffer is full.
  func send(_ bytes: [UInt8]) async {
    let peer = peer
    await OffPool.run {
      var written = 0
      while written < bytes.count {
        let n = bytes[written...].withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        guard n > 0 else { return }
        written += n
      }
    }
  }

  /// Reads exactly `count` bytes the channel wrote.
  func receive(_ count: Int) async -> String {
    let peer = peer
    return await OffPool.run {
      var bytes = [UInt8](repeating: 0, count: count)
      var got = 0
      while got < count {
        let n = bytes[got...].withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
        guard n > 0 else { break }
        got += n
      }
      return String(decoding: bytes[0..<got], as: UTF8.self)
    }
  }

  func closePeer() {
    if peer >= 0 { Darwin.close(peer) }
    peer = -1
  }

  func cleanUp() {
    closePeer()
    Darwin.close(listener)
    unlink(path)
    try? FileManager.default.removeItem(at: directory)
  }

  var logURL: URL { directory.appending(path: "serial.log") }
}

/// Polls until `condition` holds or two seconds pass.
func eventually(_ condition: () async -> Bool) async -> Bool {
  for _ in 0..<200 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

@Suite struct SerialTests {
  func connected(
    ringCapacity: Int = SerialChannel.defaultRingCapacity,
    rotateBytes: UInt64 = SerialChannel.defaultRotateBytes
  ) async throws -> (FakeSerialServer, SerialChannel) {
    let server = try FakeSerialServer()
    let channel = SerialChannel(
      socketPath: server.path, logURL: server.logURL, ringCapacity: ringCapacity,
      rotateBytes: rotateBytes)
    try await channel.start()
    await server.accept()
    return (server, channel)
  }

  @Test func offsetsAndReadSince() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send("hello\n")
    #expect(await eventually { await channel.endOffset == 6 })
    await server.send("world\n")
    #expect(await eventually { await channel.endOffset == 12 })

    let all = await channel.read(since: 0)
    #expect(all == SerialRead(text: "hello\nworld\n", start: 0, offset: 12, truncated: false))
    let rest = await channel.read(since: 6)
    #expect(rest.text == "world\n")
    #expect(rest.start == 6)
    let limited = await channel.read(since: 0, maxBytes: 3)
    #expect(limited == SerialRead(text: "hel", start: 0, offset: 3, truncated: true))
    let past = await channel.read(since: 99)
    #expect(past.text.isEmpty && past.offset == 12)
    await channel.stop()
    let log = try String(contentsOf: server.logURL, encoding: .utf8)
    #expect(log == "hello\nworld\n")
  }

  @Test func ringDropsOldBytesButKeepsAbsoluteOffsets() async throws {
    let (server, channel) = try await connected(ringCapacity: 8)
    defer { server.cleanUp() }
    await server.send("0123456789abcdef")
    #expect(await eventually { await channel.endOffset == 16 })
    #expect(await channel.startOffset == 8)
    let read = await channel.read(since: 2)
    #expect(read == SerialRead(text: "89abcdef", start: 8, offset: 16, truncated: true))
    #expect(await channel.read(since: 12).text == "cdef")
    await channel.stop()
    // The log keeps everything even though the ring does not.
    #expect(try String(contentsOf: server.logURL, encoding: .utf8) == "0123456789abcdef")
  }

  @Test func tailReturnsLastLines() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send("one\ntwo\nthree\nfour\n")
    #expect(await eventually { await channel.endOffset == 19 })
    let tail = await channel.read(tail: 2)
    #expect(tail == SerialRead(text: "three\nfour\n", start: 8, offset: 19, truncated: false))
    #expect(await channel.read(tail: 10).text == "one\ntwo\nthree\nfour\n")
    await server.send("partial")
    #expect(await eventually { await channel.endOffset == 26 })
    #expect(await channel.read(tail: 2).text == "four\npartial")
    #expect(await channel.read(tail: 0).text == "")
    await channel.stop()
  }

  @Test func waitFindsPatternInLaterOutput() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send("Booting...\n")
    #expect(await eventually { await channel.endOffset == 11 })
    async let found = channel.wait(for: "log[a-z]+:", timeout: .seconds(5))
    try await Task.sleep(for: .milliseconds(50))
    await server.send("debian ")
    try await Task.sleep(for: .milliseconds(20))
    await server.send("login: ")
    let match = try await found
    #expect(match == SerialMatch(match: "login:", start: 18, offset: 24))
    await channel.stop()
  }

  @Test func waitSinceZeroSeesEarlierOutputAndDefaultDoesNot() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send("prompt$ ")
    #expect(await eventually { await channel.endOffset == 8 })
    let early = try await channel.wait(for: "\\$ ", since: 0, timeout: .seconds(1))
    #expect(early.offset == 8)
    await #expect(throws: VMLabError.self) {
      try await channel.wait(for: "\\$ ", timeout: .milliseconds(100))
    }
    await channel.stop()
  }

  @Test func waitTimesOutWithTimeoutCode() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send("nothing here\n")
    let started = ContinuousClock.now
    do {
      _ = try await channel.wait(for: "login:", since: 0, timeout: .milliseconds(200))
      Issue.record("wait should have timed out")
    } catch let error as VMLabError {
      #expect(error.code == .timeout)
      #expect(error.data["pattern"] == .string("login:"))
      // R-1101: the partial output comes back with the timeout.
      #expect(error.data["text"] == .string("nothing here\n"))
      #expect(error.data["truncated"] == .bool(false))
    }
    #expect(ContinuousClock.now - started >= .milliseconds(190))
    await channel.stop()
  }

  @Test func invalidPatternIsInvalidRequest() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    do {
      _ = try await channel.wait(for: "(unclosed", timeout: .seconds(1))
      Issue.record("expected invalid_request")
    } catch let error as VMLabError {
      #expect(error.code == .invalidRequest)
      #expect(error.data["field"] == .string("pattern"))
    }
    await channel.stop()
  }

  @Test func waitFailsWhenGuestGoesAway() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    async let found = channel.wait(for: "never", timeout: .seconds(10))
    try await Task.sleep(for: .milliseconds(50))
    server.closePeer()
    do {
      _ = try await found
      Issue.record("expected guest_unreachable")
    } catch let error as VMLabError {
      #expect(error.code == .guestUnreachable)
    }
    #expect(await eventually { await !channel.isConnected })
    await #expect(throws: VMLabError.self) { try await channel.write("x") }
  }

  /// `waitOrEnd` tells "the reader ended with no match" from a timeout (R-1201).
  @Test func waitOrEndReportsTheEndDistinctlyFromATimeout() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send("halting\n")
    #expect(await eventually { await channel.endOffset == 8 })
    await #expect {
      try await channel.waitOrEnd(for: "never", since: 0, timeout: .milliseconds(200))
    } throws: { ($0 as? VMLabError)?.code == .timeout }
    async let outcome = channel.waitOrEnd(for: "never", since: 0, timeout: .seconds(10))
    try await Task.sleep(for: .milliseconds(50))
    server.closePeer()
    #expect(try await outcome == .ended(offset: 8))
    // After the end: a match in what arrived is still a match, and no match ends at once.
    #expect(
      try await channel.waitOrEnd(for: "halt", since: 0, timeout: .seconds(10))
        == .matched(SerialMatch(match: "halt", start: 0, offset: 4)))
    #expect(
      try await channel.waitOrEnd(for: "n[e]ver", since: 0, timeout: .seconds(10))
        == .ended(offset: 8))
    await channel.stop()
  }

  /// `openLog` reads a console log no engine writes: reads and tails answer from the file, and a
  /// wait ends once it has scanned it.
  @Test func openLogAnswersFromTheFileAndEnds() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "vmlab-openlog-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appending(path: "console.log")
    try Data("one\ntwo\nthree\n".utf8).write(to: log)
    let channel = SerialChannel(
      socketPath: "", logURL: directory.appending(path: "serial.log"), consoleLog: log)
    #expect(await channel.openLog())
    #expect(await !channel.isConnected)
    #expect(await channel.read(since: 4).text == "two\nthree\n")
    #expect(
      await channel.read(tail: 1)
        == SerialRead(text: "three\n", start: 8, offset: 14, truncated: false))
    #expect(
      try await channel.waitOrEnd(for: "t[wh]", since: 0, timeout: .seconds(10))
        == .matched(SerialMatch(match: "tw", start: 4, offset: 6)))
    #expect(
      try await channel.waitOrEnd(for: "four", since: 0, timeout: .seconds(10))
        == .ended(offset: 14))
    #expect(
      try await channel.waitOrEnd(for: "one", since: 14, timeout: .seconds(10))
        == .ended(offset: 14))
    await #expect(throws: VMLabError.self) {
      try await channel.wait(for: "four", since: 0, timeout: .seconds(10))
    }
    await channel.stop()
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "serial.log").path))
    // No log: nothing to open, and nothing is created.
    let gone = directory.appending(path: "gone/console.log")
    let none = SerialChannel(
      socketPath: "", logURL: directory.appending(path: "serial.log"), consoleLog: gone)
    #expect(await !none.openLog())
    #expect(!FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path))
  }

  @Test func writeReachesTheGuest() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send("login: ")
    #expect(await eventually { await channel.endOffset == 7 })
    let offset = try await channel.write("root\n")
    #expect(offset == 7)
    #expect(await server.receive(5) == "root\n")
    await channel.stop()
  }

  /// CX-13: a guest that takes no input fails a large write with `timeout`, and reads go on
  /// meanwhile.
  @Test func writeToAGuestThatStopsReadingTimesOut() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    let big = String(repeating: "x", count: 8 << 20)
    let write = Task { try await channel.write(big, stallTimeout: .milliseconds(300)) }
    await server.send("still here")
    #expect(await eventually { await channel.endOffset == 10 })
    do {
      _ = try await write.value
      Issue.record("expected timeout")
    } catch let error as VMLabError {
      #expect(error.code == .timeout)
    }
    await channel.stop()
  }

  /// CX-13: `stop` proceeds while a write is stuck on a guest that stopped reading, and the
  /// write then fails.
  @Test(.timeLimit(.minutes(1))) func stopProceedsDuringAStuckWrite() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    let big = String(repeating: "x", count: 8 << 20)
    let write = Task { try await channel.write(big, stallTimeout: .seconds(120)) }
    try await Task.sleep(for: .milliseconds(200))
    await channel.stop()
    do {
      _ = try await write.value
      Issue.record("expected guest_unreachable")
    } catch let error as VMLabError {
      #expect(error.code == .guestUnreachable)
    }
  }

  @Test func lineObserverSeesCompletedLines() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let channel = SerialChannel(socketPath: server.path, logURL: server.logURL)
    let lines = LineCollector()
    await channel.setLineObserver { lines.add($0) }
    try await channel.start()
    await server.accept()
    await server.send("first\r\nsec")
    try await Task.sleep(for: .milliseconds(20))
    await server.send("ond\nthird")
    #expect(await eventually { await channel.endOffset == 19 })
    #expect(
      lines.all == [
        SerialLine(text: "first", start: 0, end: 7), SerialLine(text: "second", start: 7, end: 14),
      ])
    await channel.stop()
  }

  /// R-304: panic detection is one observer among others; none steals the lines.
  @Test func lineObserversAreAdditiveAndPanicsReachTheLog() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let vmDirectory = server.logURL.deletingLastPathComponent()
    let channel = SerialChannel(socketPath: server.path, logURL: server.logURL)
    let first = LineCollector()
    let second = LineCollector()
    await channel.setLineObserver { first.add($0) }
    let key = await channel.addLineObserver { second.add($0) }
    await channel.watchForPanics(vmDirectory: vmDirectory)
    try await channel.start()
    await server.accept()
    await server.send("[   12.5] Kernel panic - not syncing: sysrq triggered crash\nok\n")
    #expect(await eventually { second.all.count == 2 })
    #expect(first.all.map(\.text) == second.all.map(\.text))
    let log = EventLog(vmDirectory: vmDirectory)
    #expect(await eventually { (try? await log.latestPanic()) != nil })
    let panic = try await log.latestPanic()
    #expect(panic?.message == "[   12.5] Kernel panic - not syncing: sysrq triggered crash")
    #expect(panic?.data?["pattern"] == .string("Kernel panic - not syncing"))
    await channel.removeLineObserver(key)
    await channel.setLineObserver(nil)
    await server.send("later\n")
    #expect(await eventually { await channel.endOffset > 64 })
    #expect(second.all.count == 2 && first.all.count == 2)
    await channel.stop()
  }

  @Test func logIsAppendedAcrossRunsAndRotated() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    try Data("previous run\n".utf8).write(to: server.logURL)
    let channel = SerialChannel(
      socketPath: server.path, logURL: server.logURL, rotateBytes: 20)
    try await channel.start()
    await server.accept()
    await server.send("0123456789\n")
    #expect(await eventually { await channel.endOffset == 11 })
    await channel.stop()
    let rotated = server.directory.appending(path: "serial.log.1")
    #expect(try String(contentsOf: rotated, encoding: .utf8) == "previous run\n")
    #expect(try String(contentsOf: server.logURL, encoding: .utf8) == "0123456789\n")
  }

  @Test func startRetriesUntilTheSocketAppears() async throws {
    let id = UUID().uuidString.prefix(8)
    let path = "/tmp/vmlab-ser-\(id).sock"
    let channel = SerialChannel(
      socketPath: path, logURL: URL(fileURLWithPath: "/tmp/vmlab-ser-\(id)/serial.log"))
    do {
      try await channel.start(connectTimeout: .milliseconds(100))
      Issue.record("expected guest_unreachable")
    } catch let error as VMLabError {
      #expect(error.code == .guestUnreachable)
    }
  }

  @Test func waitMatchesUTF8AndReportsByteOffsets() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    // "é" is two bytes; send it split across chunks.
    let bytes = Array("café ok".utf8)
    await server.send(Array(bytes[0..<4]))
    try await Task.sleep(for: .milliseconds(20))
    await server.send(Array(bytes[4...]))
    let match = try await channel.wait(for: "é ok", since: 0, timeout: .seconds(2))
    #expect(match == SerialMatch(match: "é ok", start: 3, offset: 8))
    await channel.stop()
  }

  /// True once `pid` names no process, not even a zombie: it exited and was reaped.
  static func gone(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) != 0 && errno == ESRCH }

  /// CR-3: a backtracking pattern must not block the channel or outlive its wait. `(=|=)+x` is
  /// exponential in Swift Regex (minutes at 30 '=') and is not a nested quantifier, so it reaches
  /// the matcher; the wait times out on time and its `vmlab-match` process is killed and reaped.
  @Test(.timeLimit(.minutes(1))) func runawayPatternTimesOutAndLeavesNoMatcher() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send(String(repeating: "=", count: 30))
    #expect(await eventually { await channel.endOffset == 30 })
    let started = ContinuousClock.now
    async let waited: SerialMatch = channel.wait(
      for: "(=|=)+x", since: 0, timeout: .seconds(2))
    try await Task.sleep(for: .milliseconds(200))
    // Other calls on the channel answer while the match runs, and the reader keeps ingesting.
    let readStarted = ContinuousClock.now
    #expect(await channel.read(since: 0).text.count == 30)
    #expect(ContinuousClock.now - readStarted < .milliseconds(500))
    await server.send("more\n")
    #expect(await eventually { await channel.endOffset == 35 })
    do {
      _ = try await waited
      Issue.record("wait should have timed out")
    } catch let error as VMLabError {
      #expect(error.code == .timeout)
      #expect(error.data["text"] == .string(String(repeating: "=", count: 30) + "more\n"))
    }
    #expect(ContinuousClock.now - started < .seconds(3))
    #expect(await eventually { await !channel.matcherPIDs.isEmpty })
    let pids = await channel.matcherPIDs
    #expect(await eventually { pids.allSatisfy(Self.gone) }, "matchers \(pids) still exist")
    // A second wait on the same channel still works, with a matcher of its own.
    async let next = channel.wait(for: "ready", timeout: .seconds(2))
    try await Task.sleep(for: .milliseconds(50))
    await server.send("ready\n")
    #expect(try await next.match == "ready")
    await channel.stop()
  }

  /// More runaway waits than a channel has matchers: the extra ones queue, every one times out,
  /// none is refused, no matcher survives, and an ordinary wait afterwards matches at once.
  @Test(.timeLimit(.minutes(1))) func runawayWaitsQueueForMatchersAndAllEnd() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    await server.send(String(repeating: "=", count: 30))
    #expect(await eventually { await channel.endOffset == 30 })
    let count = SerialChannel.maxMatchers + 2
    let started = ContinuousClock.now
    try await withThrowingTaskGroup(of: ErrorCode?.self) { group in
      for _ in 0..<count {
        group.addTask {
          do {
            _ = try await channel.wait(for: "(=|=)+x", since: 0, timeout: .milliseconds(500))
            return nil
          } catch let error as VMLabError {
            return error.code
          } catch {
            return .internal
          }
        }
      }
      for try await code in group { #expect(code == .timeout) }
    }
    #expect(ContinuousClock.now - started < .seconds(3))
    let pids = await channel.matcherPIDs
    #expect(pids.count <= count)
    #expect(await eventually { pids.allSatisfy(Self.gone) }, "matchers \(pids) still exist")
    let match = try await channel.wait(for: "=+", since: 0, timeout: .seconds(2))
    #expect(match == SerialMatch(match: String(repeating: "=", count: 30), start: 0, offset: 30))
    await channel.stop()
  }

  @Test func missingMatcherIsEngineError() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let channel = SerialChannel(
      socketPath: server.path, logURL: server.logURL, matcherPath: "/nonexistent/vmlab-match")
    try await channel.start()
    await server.accept()
    do {
      _ = try await channel.wait(for: "log[a-z]+:", timeout: .seconds(1))
      Issue.record("expected engine_error")
    } catch let error as VMLabError {
      #expect(error.code == .engineError)
      #expect(error.data["tool"] == .string("vmlab-match"))
      #expect(error.data["path"] == .string("/nonexistent/vmlab-match"))
    }
    let unlocated = SerialChannel(
      socketPath: server.path, logURL: server.logURL, matcherPath: nil)
    await #expect(throws: VMLabError.self) {
      try await unlocated.wait(for: "x+", since: 0, timeout: .seconds(1))
    }
    // A matcher that exits instead of answering (no SIGPIPE reaches the server either).
    let other = try FakeSerialServer()
    defer { other.cleanUp() }
    let broken = SerialChannel(
      socketPath: other.path, logURL: other.logURL, matcherPath: "/usr/bin/true")
    try await broken.start()
    await other.accept()
    await other.send("abc")
    #expect(await eventually { await broken.endOffset == 3 })
    do {
      _ = try await broken.wait(for: "x+", since: 0, timeout: .seconds(2))
      Issue.record("expected engine_error")
    } catch let error as VMLabError {
      #expect(error.code == .engineError)
    }
    await broken.stop()
    await channel.stop()
  }

  @Test func matcherIsLocatedBesideTheTestBundleOrByEnvironment() {
    let found = SerialMatcher.locate(environment: [:])
    #expect(found?.hasSuffix("/vmlab-match") == true)
    #expect(SerialMatcher.locate(environment: ["VMLAB_MATCH_HELPER": "/bin/ls"]) == "/bin/ls")
    #expect(SerialMatcher.locate(environment: ["VMLAB_MATCH_HELPER": "/nonexistent"]) == nil)
  }

  /// A plain literal (escaped punctuation allowed) is matched in-process: no matcher is needed or
  /// launched, and offsets are bytes.
  @Test func literalPatternsNeedNoMatcher() async throws {
    #expect(SerialMatcher.literal(of: "login:") == "login:")
    #expect(SerialMatcher.literal(of: "\\$ ") == "$ ")
    #expect(SerialMatcher.literal(of: "a\\.b\\(c\\)") == "a.b(c)")
    for regex in ["=+", "\\$ $", "^x", "a|b", "[ab]", "\\d", "x{2}", "(?i)x", "a.b", ""] {
      #expect(SerialMatcher.literal(of: regex) == nil, "\(regex)")
    }
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let channel = SerialChannel(socketPath: server.path, logURL: server.logURL, matcherPath: nil)
    try await channel.start()
    await server.accept()
    await server.send("café prompt$ ")
    #expect(await eventually { await channel.endOffset == 14 })
    let match = try await channel.wait(for: "prompt\\$ ", since: 0, timeout: .seconds(1))
    #expect(match == SerialMatch(match: "prompt$ ", start: 6, offset: 14))
    #expect(await channel.matcherPIDs.isEmpty)
    await channel.stop()
  }

  /// A matcher that takes longer to start than the wait's whole timeout does not make an ordinary
  /// pattern time out: start-up time is added to the deadline.
  @Test(.timeLimit(.minutes(1))) func slowMatcherStartDoesNotCountAgainstTheTimeout()
    async throws
  {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let real = try #require(SerialMatcher.locate(environment: [:]))
    let script = server.directory.appending(path: "slow-match")
    try TestScripts.install("#!/bin/sh\nsleep 1.5\nexec '\(real)'\n", at: script)
    let channel = SerialChannel(
      socketPath: server.path, logURL: server.logURL, matcherPath: script.path)
    try await channel.start()
    await server.accept()
    await server.send("== done\n")
    #expect(await eventually { await channel.endOffset == 8 })
    // The first wait gets the spare while it is still starting; the second starts a matcher.
    let first = try await channel.wait(for: "=+ done", since: 0, timeout: .milliseconds(500))
    #expect(first == SerialMatch(match: "== done", start: 0, offset: 7))
    let second = try await channel.wait(for: "d[aeiou]ne", since: 0, timeout: .milliseconds(500))
    #expect(second.start == 3)
    await channel.stop()
  }

  /// Output arriving a few bytes at a time is matched with correct offsets, with far fewer matcher
  /// round trips than chunks (the rescan interval batches them), by one matcher per wait.
  @Test func tricklingOutputMatchesWithOneMatcher() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    async let found = channel.wait(for: "login: $", timeout: .seconds(10))
    try await Task.sleep(for: .milliseconds(50))
    let text = String(repeating: "booting...\n", count: 20) + "debian login: "
    for byte in text.utf8 {
      await server.send([byte])
      try await Task.sleep(for: .milliseconds(1))
    }
    let match = try await found
    let total = UInt64(text.utf8.count)
    #expect(match == SerialMatch(match: "login: ", start: total - 7, offset: total))
    #expect(await channel.matcherPIDs.count == 1)
    await channel.stop()
  }

  @Test func nestedQuantifiersAndLongPatternsAreInvalidRequest() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    for pattern in [
      "(=+)+x", "(a*)*", "(?:a+b?)*c", "((ab)+c)+", "(x+){2,}", String(repeating: "a", count: 2000),
    ] {
      do {
        _ = try await channel.wait(for: pattern, timeout: .seconds(1))
        Issue.record("expected invalid_request for \(pattern.prefix(20))")
      } catch let error as VMLabError {
        #expect(error.code == .invalidRequest)
        #expect(error.data["field"] == .string("pattern"))
      }
    }
    // Ordinary patterns, including bounded repeats of quantified groups, are accepted.
    for pattern in ["login:", "(\\d+\\.){3}\\d+", "[(+)]+x", "\\(a+\\)+", "(ab)+c", "a+b*"] {
      #expect(SerialChannel.rejection(for: pattern) == nil, "\(pattern)")
    }
    await channel.stop()
  }

  @Test func waitScansLargeBacklogInWindows() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    let filler = String(repeating: "x", count: 200_000)
    await server.send(filler + "MARK" + filler)
    #expect(await eventually { await channel.endOffset == 400_004 })
    let match = try await channel.wait(for: "MARK", since: 0, timeout: .seconds(5))
    #expect(match == SerialMatch(match: "MARK", start: 200_000, offset: 200_004))
    await channel.stop()
  }

  @Test func ringWrapsAcrossManyAppends() {
    var ring = ByteRing(capacity: 5)
    for chunk in ["ab", "cd", "ef", "g"] { ring.append(Array(chunk.utf8)) }
    #expect(ring.start == 2 && ring.end == 7)
    #expect(String(decoding: ring.bytes(from: 0, to: 7), as: UTF8.self) == "cdefg")
    #expect(String(decoding: ring.bytes(from: 4, to: 6), as: UTF8.self) == "ef")
    #expect(ring.byte(at: 6) == UInt8(ascii: "g"))
  }
}

final class LineCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [SerialLine] = []
  func add(_ line: SerialLine) {
    lock.lock()
    lines.append(line)
    lock.unlock()
  }
  var all: [SerialLine] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
}
