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

  /// Accepts the channel's connection (call after `start`, which has connected by then).
  func accept() {
    peer = Darwin.accept(listener, nil, nil)
    #expect(peer >= 0)
  }

  func send(_ text: String) { send(Array(text.utf8)) }

  func send(_ bytes: [UInt8]) {
    var written = 0
    while written < bytes.count {
      let n = bytes[written...].withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
      guard n > 0 else { return }
      written += n
    }
  }

  /// Reads exactly `count` bytes the channel wrote.
  func receive(_ count: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
      let n = bytes[got...].withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
      guard n > 0 else { break }
      got += n
    }
    return String(decoding: bytes[0..<got], as: UTF8.self)
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
    server.accept()
    return (server, channel)
  }

  @Test func offsetsAndReadSince() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    server.send("hello\n")
    #expect(await eventually { await channel.endOffset == 6 })
    server.send("world\n")
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
    server.send("0123456789abcdef")
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
    server.send("one\ntwo\nthree\nfour\n")
    #expect(await eventually { await channel.endOffset == 19 })
    let tail = await channel.read(tail: 2)
    #expect(tail == SerialRead(text: "three\nfour\n", start: 8, offset: 19, truncated: false))
    #expect(await channel.read(tail: 10).text == "one\ntwo\nthree\nfour\n")
    server.send("partial")
    #expect(await eventually { await channel.endOffset == 26 })
    #expect(await channel.read(tail: 2).text == "four\npartial")
    #expect(await channel.read(tail: 0).text == "")
    await channel.stop()
  }

  @Test func waitFindsPatternInLaterOutput() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    server.send("Booting...\n")
    #expect(await eventually { await channel.endOffset == 11 })
    async let found = channel.wait(for: "log[a-z]+:", timeout: .seconds(5))
    try await Task.sleep(for: .milliseconds(50))
    server.send("debian ")
    try await Task.sleep(for: .milliseconds(20))
    server.send("login: ")
    let match = try await found
    #expect(match == SerialMatch(match: "login:", start: 18, offset: 24))
    await channel.stop()
  }

  @Test func waitSinceZeroSeesEarlierOutputAndDefaultDoesNot() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    server.send("prompt$ ")
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
    server.send("nothing here\n")
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

  @Test func writeReachesTheGuest() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    server.send("login: ")
    #expect(await eventually { await channel.endOffset == 7 })
    let offset = try await channel.write("root\n")
    #expect(offset == 7)
    #expect(server.receive(5) == "root\n")
    await channel.stop()
  }

  @Test func lineObserverSeesCompletedLines() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let channel = SerialChannel(socketPath: server.path, logURL: server.logURL)
    let lines = LineCollector()
    await channel.setLineObserver { lines.add($0) }
    try await channel.start()
    server.accept()
    server.send("first\r\nsec")
    try await Task.sleep(for: .milliseconds(20))
    server.send("ond\nthird")
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
    server.accept()
    server.send("[   12.5] Kernel panic - not syncing: sysrq triggered crash\nok\n")
    #expect(await eventually { second.all.count == 2 })
    #expect(first.all.map(\.text) == second.all.map(\.text))
    let log = EventLog(vmDirectory: vmDirectory)
    #expect(await eventually { (try? await log.latestPanic()) != nil })
    let panic = try await log.latestPanic()
    #expect(panic?.message == "[   12.5] Kernel panic - not syncing: sysrq triggered crash")
    #expect(panic?.data?["pattern"] == .string("Kernel panic - not syncing"))
    await channel.removeLineObserver(key)
    await channel.setLineObserver(nil)
    server.send("later\n")
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
    server.accept()
    server.send("0123456789\n")
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
    server.send(Array(bytes[0..<4]))
    try await Task.sleep(for: .milliseconds(20))
    server.send(Array(bytes[4...]))
    let match = try await channel.wait(for: "é ok", since: 0, timeout: .seconds(2))
    #expect(match == SerialMatch(match: "é ok", start: 3, offset: 8))
    await channel.stop()
  }

  /// CR-3: a backtracking pattern must not block the channel. `(=|=)+x` is exponential in Swift
  /// Regex (about a second at 18 '=', four times longer per two more) and is not a nested
  /// quantifier, so it reaches the matcher. 22 '=' keeps the abandoned match to ~15 s of CPU.
  @Test(.timeLimit(.minutes(1))) func runawayPatternStillTimesOutAndChannelStaysLive()
    async throws
  {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    server.send(String(repeating: "=", count: 22))
    #expect(await eventually { await channel.endOffset == 22 })
    let started = ContinuousClock.now
    async let waited: SerialMatch = channel.wait(
      for: "(=|=)+x", since: 0, timeout: .seconds(2))
    try await Task.sleep(for: .milliseconds(200))
    // Other calls on the channel answer while the match runs, and the reader keeps ingesting.
    let readStarted = ContinuousClock.now
    #expect(await channel.read(since: 0).text.count == 22)
    #expect(ContinuousClock.now - readStarted < .milliseconds(500))
    server.send("more\n")
    #expect(await eventually { await channel.endOffset == 27 })
    do {
      _ = try await waited
      Issue.record("wait should have timed out")
    } catch let error as VMLabError {
      #expect(error.code == .timeout)
    }
    #expect(ContinuousClock.now - started < .seconds(3))
    // A second wait on the same channel still works.
    async let next = channel.wait(for: "ready", timeout: .seconds(2))
    try await Task.sleep(for: .milliseconds(50))
    server.send("ready\n")
    #expect(try await next.match == "ready")
    await channel.stop()
  }

  @Test(.timeLimit(.minutes(1))) func abandonedMatchesAreBoundedPerChannel() async throws {
    let (server, channel) = try await connected()
    defer { server.cleanUp() }
    // About 3.5 s of backtracking each, far past the waits' timeouts.
    server.send(String(repeating: "=", count: 20))
    #expect(await eventually { await channel.endOffset == 20 })
    for _ in 0..<SerialChannel.maxAbandonedScans {
      await #expect(throws: VMLabError.self) {
        try await channel.wait(for: "(=|=)+x", since: 0, timeout: .milliseconds(100))
      }
    }
    do {
      _ = try await channel.wait(for: "=", since: 0, timeout: .seconds(1))
      Issue.record("expected invalid_request while the runaway matches run")
    } catch let error as VMLabError {
      #expect(error.code == .invalidRequest)
    }
    // Once they finish on their own, waits are accepted again.
    var accepted = false
    for _ in 0..<300 where !accepted {
      accepted = (try? await channel.wait(for: "=", since: 0, timeout: .seconds(1))) != nil
      if !accepted { try await Task.sleep(for: .milliseconds(100)) }
    }
    #expect(accepted)
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
    server.send(filler + "MARK" + filler)
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
