import Foundation

/// Bytes read back from a serial channel. Offsets are byte offsets into the VM's console log when
/// the channel has one (`SerialChannel.consoleLog`), else they count bytes from the first byte the
/// channel received.
public struct SerialRead: Sendable, Hashable {
  /// The returned bytes, decoded as UTF-8 (invalid sequences become U+FFFD).
  public var text: String
  /// The offset of the first returned byte.
  public var start: UInt64
  /// The offset after the last returned byte: the `since` for the next read.
  public var offset: UInt64
  /// True when bytes in the requested range are not in `text`: they fell out of the ring, or a
  /// byte limit cut the read short.
  public var truncated: Bool

  public init(text: String, start: UInt64, offset: UInt64, truncated: Bool) {
    self.text = text
    self.start = start
    self.offset = offset
    self.truncated = truncated
  }
}

/// A `wait` that found its pattern.
public struct SerialMatch: Sendable, Hashable {
  /// The matched text.
  public var match: String
  /// The offset of the first matched byte.
  public var start: UInt64
  /// The offset after the match: the `since` for the next wait.
  public var offset: UInt64

  public init(match: String, start: UInt64, offset: UInt64) {
    self.match = match
    self.start = start
    self.offset = offset
  }
}

/// How a `waitOrEnd` ended: its pattern matched, or the channel's output ended first (the reader
/// stopped, or the channel reads a log no engine writes, `openLog`) with no match at or after
/// `since`.
public enum SerialWaitOutcome: Sendable, Hashable {
  case matched(SerialMatch)
  /// No match; `offset` is the end of the output.
  case ended(offset: UInt64)
}

/// One completed line of serial output, handed to the line observer (R-304's panic detection).
public struct SerialLine: Sendable, Hashable {
  /// The line without its `\n` or a trailing `\r`.
  public var text: String
  /// The offset of the line's first byte.
  public var start: UInt64
  /// The offset after the line's `\n`.
  public var end: UInt64

  public init(text: String, start: UInt64, end: UInt64) {
    self.text = text
    self.start = start
    self.end = end
  }
}

/// A guest's serial console over a unix stream socket (QEMU's `-serial unix:...,server,nowait`, or
/// the `vmlab-vz` runner's bridge, R-602).
///
/// With a `consoleLog` (every engine has one: QEMU's chardev `logfile`, the VZ runner's
/// `console.log`), the engine's own durable log is the record. Offsets are byte offsets into that
/// file, so they mean the same in every process: a CLI call, the MCP server, the server after a
/// restart. `start` loads the log's tail into the ring, then follows the file (woken by the socket,
/// and polled every `followInterval`); reads and waits older than the ring are served from the
/// file. Bytes on the socket only wake the channel; writes go to the socket. The engine appends to
/// the log for the life of the VM directory and nothing rotates it, since the engine holds it
/// open (G6: offsets never move).
///
/// Without one (tests, older callers), a background reader appends every socket byte to
/// `serial.log` (rotated to `serial.log.1` past `rotateBytes`) and to a ring of the last
/// `ringCapacity` bytes, and offsets count bytes this channel received.
public actor SerialChannel {
  public static let defaultRingCapacity = 4 * 1024 * 1024
  public static let defaultRotateBytes: UInt64 = 64 * 1024 * 1024
  /// How far back `wait` re-scans on each new chunk; a match longer than this can be missed.
  static let rescanOverlap: UInt64 = 4096
  /// A line longer than this is handed to the observer in pieces.
  static let maxLineBytes = 64 * 1024

  public let socketPath: String
  public let logURL: URL
  /// The engine's durable console log, when offsets are positions in it.
  public let consoleLog: URL?
  /// How often a channel with a `consoleLog` checks the file for output the socket did not wake
  /// it for (the engine logs a chunk just after sending it).
  static let followInterval: Duration = .milliseconds(25)
  public let ringCapacity: Int
  public let rotateBytes: UInt64

  private var ring: ByteRing
  private var log: SerialLog
  private var socket: SocketBox?
  private var readerTask: Task<Void, Never>?
  /// The open console log and how far it has been read into the ring.
  private var console: ConsoleFile?
  private var followTask: Task<Void, Never>?
  /// Lines are handed to observers only from this log offset on (`observeLines(from:)`).
  private var linesFrom: UInt64?
  private var closed = false
  /// Every line observer, by key; key 0 is `setLineObserver`'s slot.
  private var lineObservers: [UInt64: @Sendable (SerialLine) -> Void] = [:]
  private var nextObserverKey: UInt64 = 1
  private var partialLine: [UInt8] = []
  private var partialLineStart: UInt64 = 0
  private var waiters: [UInt64: Waiter] = [:]
  private var nextWaiterID: UInt64 = 0
  /// Waiters whose window is in their matcher now.
  private var scanning: Set<UInt64> = []
  /// The pid of every matcher this channel launched (tests check that none outlives its wait).
  private(set) var matcherPIDs: [pid_t] = []

  /// The most bytes one match runs over; a longer backlog is scanned window by window.
  static let scanWindow: UInt64 = 64 * 1024
  /// The longest pattern `wait` accepts, in UTF-8 bytes.
  public static let maxPatternBytes = 1024
  /// How many matcher processes one channel runs at once; further waits queue for a free one.
  static let maxMatchers = 4
  /// The least time between two scans of new output for one waiter, so a guest printing a byte at
  /// a time costs a matcher round trip per interval, not per byte.
  static let rescanInterval: Duration = .milliseconds(25)

  /// The most a wait's deadline moves for time spent starting its matcher (see `expire`).
  static let maxLaunchGrace: Duration = .seconds(10)

  /// The `vmlab-match` executable waits run their patterns in; nil when it was not found.
  public let matcherPath: String?
  /// A matcher started ahead of need, so a wait does not pay for the spawn (the first exec of a
  /// new binary can take a second on a busy host while macOS checks its signature).
  private var spare: MatchHelperProcess?

  private struct Waiter {
    var pattern: String
    /// The pattern's bytes when it is a plain literal, matched in-process with no matcher.
    var literal: [UInt8]?
    /// How far the deadline has moved for the matcher's start-up so far.
    var grace: Duration = .zero
    var since: UInt64
    /// Where the next match starts (the end of the last one, less `rescanOverlap`).
    var scanFrom: UInt64
    /// The end of the bytes the last match covered.
    var scannedTo: UInt64
    var continuation: CheckedContinuation<SerialMatch, any Error>
    var timer: Task<Void, Never>?
    /// The waiter's matcher process, once it has a slot; killed when the wait ends.
    var matcher: MatchHelperProcess?
    /// When the last scan that reached the end of the output finished.
    var caughtUpAt: ContinuousClock.Instant?
    /// A delayed pump is pending (`rescanInterval`).
    var deferred = false
  }

  /// A channel for the socket at `socketPath` logging to `logURL` (normally `<vm>/serial.log`).
  /// Nothing is opened until `start`. `matcherPath` is the `vmlab-match` helper `wait` runs its
  /// patterns in (default: `SerialMatcher.defaultPath`).
  public init(
    socketPath: String, logURL: URL, ringCapacity: Int = SerialChannel.defaultRingCapacity,
    rotateBytes: UInt64 = SerialChannel.defaultRotateBytes,
    matcherPath: String? = SerialMatcher.defaultPath, consoleLog: URL? = nil
  ) {
    self.matcherPath = matcherPath
    self.socketPath = socketPath
    self.logURL = logURL
    self.consoleLog = consoleLog
    self.ringCapacity = max(1, ringCapacity)
    self.rotateBytes = rotateBytes
    self.ring = ByteRing(capacity: max(1, ringCapacity))
    self.log = SerialLog(url: logURL, rotateBytes: rotateBytes)
  }

  /// A channel for `<vmDirectory>/serial.sock` logging to `<vmDirectory>/serial.log`.
  public init(vmDirectory: URL) {
    self.init(
      socketPath: vmDirectory.appending(path: "serial.sock").path,
      logURL: vmDirectory.appending(path: "serial.log"))
  }

  /// Called on the channel's executor with every completed line, in order. Sets (or clears) one
  /// observer slot; the observers `addLineObserver` adds are kept.
  public func setLineObserver(_ observer: (@Sendable (SerialLine) -> Void)?) {
    lineObservers[0] = observer
  }

  /// Adds an observer of every completed line, in order, beside any others (R-304 hangs panic
  /// detection here); the key removes it. The channel keeps the observer while it lives.
  @discardableResult
  public func addLineObserver(_ observer: @escaping @Sendable (SerialLine) -> Void) -> UInt64 {
    let key = nextObserverKey
    nextObserverKey += 1
    lineObservers[key] = observer
    return key
  }

  public func removeLineObserver(_ key: UInt64) { lineObservers[key] = nil }

  /// With a `consoleLog`: hand observers the lines from log offset `offset` on, including those
  /// already in the log when `start` runs (by default, only lines that arrive after it). Call it
  /// before `start`.
  public func observeLines(from offset: UInt64) { linesFrom = offset }

  /// Hangs a `PanicDetector` writing to `<vmDirectory>/events.jsonl` on this channel's lines
  /// (R-304); call it once per channel, before `start`, so no line is missed.
  public func watchForPanics(vmDirectory: URL) {
    let detector = PanicDetector(vmDirectory: vmDirectory)
    addLineObserver { line in detector.observe(line) }
  }

  /// Connects to the socket (retrying while it does not exist or refuses, up to `connectTimeout`),
  /// opens the log for appending and starts the reader.
  public func start(connectTimeout: Duration = .seconds(5)) async throws {
    guard socket == nil, !closed else { return }
    let deadline = ContinuousClock.now + connectTimeout
    var fd: Int32
    while true {
      do {
        fd = try SerialSocket.connect(path: socketPath)
        break
      } catch let error as SerialSocket.ConnectError where error.retryable {
        guard ContinuousClock.now < deadline else {
          throw VMLabError(
            code: .guestUnreachable, message: "The serial socket did not accept a connection.",
            hint: "Check that the guest is running and owns \(socketPath).",
            data: ["socket": .string(socketPath), "errno": .number(Double(error.errno))])
        }
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    do {
      if let consoleLog {
        console = try ConsoleFile(url: consoleLog)
      } else {
        try log.open()
      }
    } catch {
      Darwin.close(fd)
      throw error
    }
    // Non-blocking, so a write never waits inside the descriptor's lock (CX-13).
    SocketSend.setNonBlocking(fd)
    let box = SocketBox(fd: fd)
    socket = box
    let readFD = fd
    let chunks = AsyncStream<[UInt8]> { continuation in
      let thread = Thread {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
          let n = buffer.withUnsafeMutableBytes { SocketSend.read(readFD, into: $0) }
          if n > 0 {
            continuation.yield(Array(buffer[0..<n]))
          } else {
            break
          }
        }
        box.close()
        continuation.finish()
      }
      thread.name = "vmlab.serial.reader"
      thread.start()
    }
    refillSpare()
    if let console {
      // The ring starts at the log's tail (or where line observers start, if earlier).
      let size = console.size
      let tail = size > UInt64(ringCapacity) ? size - UInt64(ringCapacity) : 0
      let observeFrom = min(linesFrom ?? size, size)
      linesFrom = observeFrom
      ring = ByteRing(capacity: ringCapacity, base: min(tail, observeFrom))
      partialLineStart = ring.end
      follow()
      readerTask = Task { [weak self] in
        for await _ in chunks { await self?.follow() }
        await self?.readerFinished()
      }
      followTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: Self.followInterval)
          guard let self else { return }
          await self.follow()
        }
      }
    } else {
      readerTask = Task { [weak self] in
        for await chunk in chunks { await self?.ingest(chunk) }
        await self?.readerFinished()
      }
    }
  }

  /// Opens the console log with no socket and no engine behind it (a guest that is not running,
  /// R-1201): reads and tails answer from the file as it is now, and a wait that finds no match
  /// in it ends (`SerialWaitOutcome.ended`) rather than waiting. Needs a `consoleLog`; `stop`
  /// closes it.
  public func openLog() throws {
    guard socket == nil, console == nil, !closed, let consoleLog else { return }
    let file = try ConsoleFile(url: consoleLog)
    console = file
    let size = file.size
    ring = ByteRing(
      capacity: ringCapacity, base: size > UInt64(ringCapacity) ? size - UInt64(ringCapacity) : 0)
    linesFrom = size
    partialLineStart = ring.end
    follow()
  }

  /// Reads what the console log gained since the last look into the ring.
  private func follow() {
    guard let console else { return }
    let size = console.size
    // A log that shrank was replaced under the engine; offsets past its end wait for it to grow.
    while ring.end < size {
      let to = min(size, ring.end + (1 << 20))
      let chunk = console.read(from: ring.end, to: to)
      guard !chunk.isEmpty else { return }
      ingest(chunk)
    }
  }

  /// Stops the reader and closes the socket and log. Pending waits fail with `guest_unreachable`.
  public func stop() async {
    closed = true
    followTask?.cancel()
    followTask = nil
    socket?.shutdown()
    await readerTask?.value
    readerFinished(failingAll: true)
  }

  /// The offset after the last byte received.
  public var endOffset: UInt64 { ring.end }

  /// The oldest offset `read` and `wait` can reach: 0 with a console log (the file has every
  /// byte), else the oldest byte still in the ring.
  public var startOffset: UInt64 { retainedStart }

  private var retainedStart: UInt64 { console != nil ? 0 : ring.start }

  /// The bytes in `[from, to)`: from the ring, and from the console log below the ring's start.
  private func bytes(from: UInt64, to: UInt64) -> [UInt8] {
    guard let console, from < ring.start else { return ring.bytes(from: from, to: to) }
    return console.read(from: from, to: min(to, ring.start)) + ring.bytes(from: ring.start, to: to)
  }

  /// True while the reader is connected.
  public var isConnected: Bool { socket != nil && !closed }

  /// Bytes from `since` to the end, at most `maxBytes` of them. A `since` older than what is
  /// retained (`startOffset`) starts at the oldest retained byte with `truncated` set; one past the
  /// end returns nothing.
  public func read(since: UInt64, maxBytes: Int? = nil) -> SerialRead {
    let oldest = retainedStart
    let from = min(max(since, oldest), ring.end)
    var to = ring.end
    if let maxBytes, maxBytes >= 0 { to = min(to, from + UInt64(maxBytes)) }
    let bytes = bytes(from: from, to: to)
    return SerialRead(
      text: String(decoding: bytes, as: UTF8.self), start: from, offset: to,
      truncated: since < oldest || to < ring.end)
  }

  /// The last `lines` lines in the ring (a trailing partial line counts as one).
  public func read(tail lines: Int) -> SerialRead {
    let end = ring.end
    guard lines > 0, end > ring.start else {
      return SerialRead(text: "", start: end, offset: end, truncated: false)
    }
    var position = end
    // A final newline ends the last line rather than starting an empty one.
    if ring.byte(at: end - 1) == 0x0A { position -= 1 }
    var found = 0
    var start = ring.start
    while position > ring.start {
      if ring.byte(at: position - 1) == 0x0A {
        found += 1
        if found == lines {
          start = position
          break
        }
      }
      position -= 1
    }
    let truncated = start == ring.start && ring.start > 0
    let bytes = ring.bytes(from: start, to: end)
    return SerialRead(
      text: String(decoding: bytes, as: UTF8.self), start: start, offset: end,
      truncated: truncated)
  }

  /// Sends `text` to the guest as UTF-8, unchanged (callers add `\n` or `\r`). Returns the end
  /// offset at the time of the write, so a following `wait(since:)` sees only the reply.
  /// The write runs on a thread of its own, off the channel, and gives up with `timeout` once the
  /// guest has taken no byte for `stallTimeout` (a paused guest stops reading), so neither a
  /// large write nor a stuck guest holds up reads, waits or `stop` (CX-13).
  @discardableResult
  public func write(_ text: String, stallTimeout: Duration = .seconds(10)) async throws -> UInt64 {
    guard let socket, !closed else { throw Self.unreachable(socketPath) }
    let mark = ring.end
    let (bytes, path) = (Array(text.utf8), socketPath)
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
      let thread = Thread {
        do {
          try socket.write(bytes, path: path, stall: stallTimeout)
          done.resume()
        } catch {
          done.resume(throwing: error)
        }
      }
      thread.name = "vmlab.serial.writer"
      thread.start()
    }
    return mark
  }

  /// Waits until `pattern` (Swift `Regex` syntax) matches output at or after `since` (default: the
  /// current end, so only new output counts), or fails with `timeout` after `timeout`. The pattern
  /// is matched against the retained output in windows of at most 64 KB, then against new output
  /// re-scanning the last 4 KB. A plain literal (`SerialMatcher.literal(of:)`) is found by a byte
  /// search on the channel. Any other pattern runs in a `vmlab-match` process of the wait's own,
  /// killed when the wait ends, so a pattern that backtracks for ever times out, stalls neither
  /// reads nor the reader, and leaves no CPU busy; time spent starting that process does not count
  /// against `timeout` (up to `maxLaunchGrace`). Fails with `engine_error` when the helper is
  /// missing, and with `guest_unreachable` when the output ends with no match.
  public func wait(
    for pattern: String, since: UInt64? = nil, timeout: Duration
  ) async throws -> SerialMatch {
    switch try await waitOrEnd(for: pattern, since: since, timeout: timeout) {
    case .matched(let match): return match
    case .ended: throw Self.unreachable(socketPath)
    }
  }

  /// `wait`, except that output ending with no match (the reader stopped once every byte it
  /// received was scanned, or there was never a reader) is `.ended` with the end offset, not an
  /// error: the guest stopped printing, which a caller tells from a `timeout` (R-1201). `stop`
  /// still fails a pending wait with `guest_unreachable`.
  public func waitOrEnd(
    for pattern: String, since: UInt64? = nil, timeout: Duration
  ) async throws -> SerialWaitOutcome {
    if let reason = Self.rejection(for: pattern) {
      throw VMLabError.invalidRequest(
        field: "pattern", reason: reason,
        hint: "Match a plainer pattern, for example \"login:\" or \"=+ done\"; a quantifier on a "
          + "group that already repeats backtracks exponentially.")
    }
    do {
      _ = try Regex(pattern)
    } catch {
      throw VMLabError.invalidRequest(
        field: "pattern", reason: "not a valid regular expression: \(error)",
        hint: "Pass a Swift Regex pattern, for example \"login:\" or \"\\\\$ $\".")
    }
    let literal = SerialMatcher.literal(of: pattern).map { Array($0.utf8) }
    if literal == nil {
      guard let matcherPath, FileManager.default.isExecutableFile(atPath: matcherPath) else {
        throw SerialMatcher.missing(matcherPath)
      }
    }
    let from = since ?? ring.end
    let connected = !closed && socket != nil
    guard connected || max(from, retainedStart) < ring.end else {
      if closed { throw Self.unreachable(socketPath) }
      return .ended(offset: ring.end)
    }
    let id = nextWaiterID
    nextWaiterID += 1
    do {
      return .matched(
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            waiters[id] = Waiter(
              pattern: pattern, literal: literal, since: from, scanFrom: max(from, retainedStart),
              scannedTo: from,
              continuation: continuation, timer: nil)
            arm(id, after: timeout, pattern: pattern, timeout: timeout)
            pump(id)
          }
        } onCancel: {
          Task { await self.cancelWaiter(id) }
        })
    } catch let ended as OutputEnded {
      return .ended(offset: ended.offset)
    }
  }

  /// A waiter caught up with output that will not grow: no match.
  private struct OutputEnded: Error {
    var offset: UInt64
  }

  /// How a waiter that caught up with output that will not grow ends: `.ended`, or
  /// `guest_unreachable` once `stop` closed the channel.
  private var outputEnded: any Error {
    closed ? Self.unreachable(socketPath) : OutputEnded(offset: ring.end)
  }

  /// Why `pattern` is refused before compiling, or nil: longer than `maxPatternBytes`, or a group
  /// that holds an unbounded quantifier is itself repeated without bound (`(a+)+`, `(a*)*`,
  /// `(?:a+b)*`, `(a+){2,}`), the classic exponential-backtracking shape. The matcher process is
  /// killed at the deadline whatever the pattern, so this check only spares launching one for a
  /// pattern that would almost surely run to the timeout; not every slow pattern is caught.
  static func rejection(for pattern: String) -> String? {
    if pattern.utf8.count > maxPatternBytes {
      return "the pattern is \(pattern.utf8.count) bytes; the limit is \(maxPatternBytes)"
    }
    let chars = Array(pattern)
    // One frame per open group: does it contain an unbounded quantifier?
    var frames: [Bool] = [false]
    var i = 0
    /// Reads a quantifier at `i`, if any; returns whether it is unbounded and advances past it.
    func quantifier() -> Bool? {
      guard i < chars.count else { return nil }
      var unbounded: Bool
      switch chars[i] {
      case "*", "+":
        unbounded = true
        i += 1
      case "?":
        unbounded = false
        i += 1
      case "{":
        guard let close = chars[i...].firstIndex(of: "}") else { return nil }
        let body = String(chars[(i + 1)..<close])
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
          !parts[0].isEmpty
        else { return nil }
        // `{n,}` is unbounded; so, for this purpose, is a large upper bound.
        unbounded = parts.count == 2 && (parts[1].isEmpty || (Int(parts[1]) ?? .max) > 16)
        i = close + 1
      default:
        return nil
      }
      // A lazy or possessive suffix.
      if i < chars.count, chars[i] == "?" || chars[i] == "+" { i += 1 }
      return unbounded
    }
    while i < chars.count {
      let c = chars[i]
      switch c {
      case "\\":
        i += 2
        if quantifier() == true { frames[frames.count - 1] = true }
      case "[":
        // Skip the class: a leading `^` and `]` are literal, escapes skip a character.
        i += 1
        if i < chars.count, chars[i] == "^" { i += 1 }
        if i < chars.count, chars[i] == "]" { i += 1 }
        while i < chars.count, chars[i] != "]" { i += chars[i] == "\\" ? 2 : 1 }
        i += 1
        if quantifier() == true { frames[frames.count - 1] = true }
      case "(":
        frames.append(false)
        i += 1
        // `(?:`, `(?<name>` and friends: the `?` is not a quantifier.
        if i < chars.count, chars[i] == "?" { i += 1 }
      case ")":
        let inner = frames.count > 1 ? frames.removeLast() : false
        i += 1
        let outer = quantifier()
        if inner, outer == true {
          return "a repeated group repeats a quantifier inside it, which backtracks exponentially"
        }
        if inner || outer == true { frames[frames.count - 1] = true }
      default:
        i += 1
        if quantifier() == true { frames[frames.count - 1] = true }
      }
    }
    return nil
  }

  // MARK: - Reader side

  private func ingest(_ chunk: [UInt8]) {
    let chunkStart = ring.end
    ring.append(chunk)
    if console == nil { log.write(chunk) }
    if let linesFrom, chunkStart < linesFrom {
      // Bytes before the observers' start (the log's history at `start`) are not lines to report.
      let skip = Int(min(UInt64(chunk.count), linesFrom - chunkStart))
      if skip < chunk.count {
        partialLineStart = linesFrom
        emitLines(Array(chunk[skip...]), startingAt: linesFrom)
      }
    } else {
      emitLines(chunk, startingAt: chunkStart)
    }
    checkWaiters()
  }

  private func emitLines(_ chunk: [UInt8], startingAt chunkStart: UInt64) {
    guard !lineObservers.isEmpty else { return }
    let observers = lineObservers.keys.sorted().compactMap { lineObservers[$0] }
    let observer: @Sendable (SerialLine) -> Void = { line in
      for each in observers { each(line) }
    }
    var offset = chunkStart
    if partialLine.isEmpty { partialLineStart = chunkStart }
    for byte in chunk {
      offset += 1
      if byte == 0x0A || partialLine.count >= Self.maxLineBytes {
        var line = partialLine
        if byte != 0x0A { line.append(byte) }
        if line.last == 0x0D { line.removeLast() }
        observer(
          SerialLine(
            text: String(decoding: line, as: UTF8.self), start: partialLineStart, end: offset))
        partialLine.removeAll(keepingCapacity: true)
        partialLineStart = offset
      } else {
        partialLine.append(byte)
      }
    }
  }

  private func checkWaiters() {
    for id in waiters.keys { pump(id) }
  }

  /// Sends waiter `id`'s next window to its matcher, unless a scan is running, there is no
  /// unscanned output, the channel's matchers are all busy (the waiter queues), or the waiter
  /// caught up less than `rescanInterval` ago (a delayed pump follows).
  private func pump(_ id: UInt64) {
    guard let waiter = waiters[id], !scanning.contains(id), !waiter.deferred else { return }
    guard ring.end > waiter.scannedTo else {
      if socket == nil { finish(id, throwing: outputEnded) }
      return
    }
    let from = max(waiter.scanFrom, retainedStart)
    guard from < ring.end else {
      waiters[id]?.scannedTo = ring.end
      if socket == nil { finish(id, throwing: outputEnded) }
      return
    }
    let to = min(ring.end, from + Self.scanWindow)
    if let literal = waiter.literal {
      let found = SerialMatcher.search(
        literal: literal, in: bytes(from: from, to: to), base: from)
      scanFinished(id, outcome: found.map { .found($0) } ?? .none, through: to, pid: nil)
      return
    }
    if let caughtUpAt = waiter.caughtUpAt {
      let due = caughtUpAt + Self.rescanInterval
      if ContinuousClock.now < due {
        waiters[id]?.deferred = true
        Task { [weak self] in
          try? await Task.sleep(until: due)
          await self?.resume(id)
        }
        return
      }
    }
    let matcher: MatchHelperProcess
    if let existing = waiter.matcher {
      matcher = existing
    } else {
      guard waiters.values.count(where: { $0.matcher != nil }) < Self.maxMatchers,
        let matcherPath
      else { return }
      if let warm = spare {
        matcher = warm
        spare = nil
      } else {
        matcher = MatchHelperProcess(path: matcherPath)
      }
      matcher.assign(pattern: waiter.pattern)
      waiters[id]?.matcher = matcher
      refillSpare()
    }
    let bytes = bytes(from: from, to: to)
    scanning.insert(id)
    let thread = Thread { [weak self] in
      let outcome = matcher.scan(bytes, base: from)
      let pid = matcher.pid
      Task { await self?.scanFinished(id, outcome: outcome, through: to, pid: pid) }
    }
    thread.name = "vmlab.serial.match"
    thread.start()
  }

  /// Starts a spare matcher on a thread of its own, unless one exists, there is no helper, or the
  /// channel is closed.
  private func refillSpare() {
    guard spare == nil, !closed, socket != nil, let matcherPath,
      FileManager.default.isExecutableFile(atPath: matcherPath)
    else { return }
    let warm = MatchHelperProcess(path: matcherPath)
    spare = warm
    let thread = Thread { warm.start() }
    thread.name = "vmlab.serial.match-launch"
    thread.start()
  }

  private func resume(_ id: UInt64) {
    waiters[id]?.deferred = false
    pump(id)
  }

  private func scanFinished(
    _ id: UInt64, outcome: MatchHelperProcess.Outcome, through end: UInt64, pid: pid_t?
  ) {
    scanning.remove(id)
    if let pid, !matcherPIDs.contains(pid) { matcherPIDs.append(pid) }
    guard var waiter = waiters[id] else { return }
    switch outcome {
    case .found(let found):
      finish(id, returning: found)
    case .killed:
      // Only the end of the wait kills its matcher, and that removed the waiter.
      finish(id, throwing: SerialMatcher.missing(waiter.matcher?.path, detail: "it was killed"))
    case .failed(let error):
      finish(id, throwing: error)
    case .none:
      waiter.scannedTo = end
      waiter.scanFrom = max(waiter.since, end > Self.rescanOverlap ? end - Self.rescanOverlap : 0)
      if end >= ring.end { waiter.caughtUpAt = .now }
      waiters[id] = waiter
      pump(id)
    }
  }

  private func finish(_ id: UInt64, returning match: SerialMatch) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    end(waiter)
    waiter.continuation.resume(returning: match)
  }

  /// Ends waiter `id` with `error`, killing its matcher.
  private func finish(_ id: UInt64, throwing error: any Error) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    end(waiter)
    waiter.continuation.resume(throwing: error)
  }

  /// Kills an ended waiter's matcher and gives its slot to a queued waiter.
  private func end(_ waiter: Waiter) {
    waiter.timer?.cancel()
    guard let matcher = waiter.matcher else { return }
    matcher.kill()
    for (other, queued) in waiters where queued.matcher == nil { pump(other) }
  }

  /// The reader stopped. A waiter still matching output that arrived before the end keeps going
  /// (and ends once caught up); the rest end now. `stop` fails them all.
  private func readerFinished(failingAll: Bool = false) {
    // The engine logged the last bytes before the socket closed.
    if !failingAll { follow() }
    followTask?.cancel()
    followTask = nil
    socket = nil
    log.close()
    partialLine.removeAll()
    spare?.kill()
    spare = nil
    for id in waiters.keys where failingAll || !scanning.contains(id) {
      if failingAll { finish(id, throwing: Self.unreachable(socketPath)) } else { pump(id) }
    }
  }

  /// How much of the output a timed-out wait returns.
  public static let timeoutTextBytes: UInt64 = 4096

  /// (Re)arms waiter `id`'s deadline `delay` from now.
  private func arm(_ id: UInt64, after delay: Duration, pattern: String, timeout: Duration) {
    waiters[id]?.timer?.cancel()
    waiters[id]?.timer = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      await self?.expire(id, pattern: pattern, timeout: timeout)
    }
  }

  /// The deadline passed. Time the wait's scans spent waiting for its matcher to start is not
  /// matching time, so the deadline first moves by that much (and, while the matcher is still
  /// starting, in steps of 100 ms), up to `maxLaunchGrace` in all; then the wait times out.
  private func expire(_ id: UInt64, pattern: String, timeout: Duration) {
    guard let waiter = waiters[id] else { return }
    if let matcher = waiter.matcher, waiter.grace < Self.maxLaunchGrace {
      let owed = matcher.launchWait - waiter.grace
      let step: Duration? =
        matcher.scanIsWaitingForLaunch
        ? max(owed, .milliseconds(100)) : (owed > .zero ? owed : nil)
      if let step {
        let granted = min(step, Self.maxLaunchGrace - waiter.grace)
        waiters[id]?.grace += granted
        arm(id, after: granted, pattern: pattern, timeout: timeout)
        return
      }
    }
    // Partial data (R-1101): what the guest printed while the wait ran, its last 4 KB at most.
    let end = ring.end
    let from = max(
      waiter.since, retainedStart, end >= Self.timeoutTextBytes ? end - Self.timeoutTextBytes : 0)
    let seen = read(since: from)
    finish(
      id,
      throwing: VMLabError(
        code: .timeout, message: "The serial output did not match the pattern in time.",
        hint: "data.text is what the guest printed meanwhile; wait longer or change the pattern.",
        data: [
          "pattern": .string(pattern), "timeoutSeconds": .number(Self.seconds(timeout)),
          "offset": .number(Double(end)), "text": .string(seen.text),
          "start": .number(Double(seen.start)),
          "truncated": .bool(from > waiter.since),
        ]))
  }

  private func cancelWaiter(_ id: UInt64) { finish(id, throwing: CancellationError()) }

  // MARK: - Helpers

  private static func unreachable(_ path: String) -> VMLabError {
    VMLabError(
      code: .guestUnreachable, message: "The serial channel is not connected.",
      hint: "Start the guest, then try again.", data: ["socket": .string(path)])
  }

  private static func seconds(_ duration: Duration) -> Double {
    let (s, attos) = duration.components
    return Double(s) + Double(attos) / 1e18
  }
}

enum UTF8Tail {
  /// How many trailing bytes form an incomplete UTF-8 sequence (0 when the end is complete).
  static func incompleteSuffix(_ bytes: [UInt8]) -> Int {
    var count = 0
    var index = bytes.count - 1
    while index >= 0, count < 4 {
      let byte = bytes[index]
      count += 1
      if byte & 0xC0 != 0x80 {
        let needed: Int
        if byte & 0x80 == 0 {
          needed = 1
        } else if byte & 0xE0 == 0xC0 {
          needed = 2
        } else if byte & 0xF0 == 0xE0 {
          needed = 3
        } else if byte & 0xF8 == 0xF0 {
          needed = 4
        } else {
          return 0
        }
        return count < needed ? count : 0
      }
      index -= 1
    }
    return 0
  }
}

/// A fixed-capacity ring of bytes addressed by absolute offset.
struct ByteRing: Sendable {
  private var storage: [UInt8]
  private var head = 0
  private(set) var count = 0
  /// The offset after the newest byte.
  private(set) var end: UInt64 = 0

  /// An empty ring whose first byte will be at offset `base`.
  init(capacity: Int, base: UInt64 = 0) {
    storage = [UInt8](repeating: 0, count: capacity)
    end = base
  }

  var capacity: Int { storage.count }
  /// The offset of the oldest retained byte.
  var start: UInt64 { end - UInt64(count) }

  mutating func append(_ bytes: [UInt8]) {
    end += UInt64(bytes.count)
    let kept = bytes.suffix(capacity)
    for byte in kept {
      storage[(head + count) % capacity] = byte
      if count < capacity {
        count += 1
      } else {
        head = (head + 1) % capacity
      }
    }
  }

  func byte(at offset: UInt64) -> UInt8 {
    storage[(head + Int(offset - start)) % capacity]
  }

  /// The bytes in `[from, to)`, clamped to what is retained.
  func bytes(from: UInt64, to: UInt64) -> [UInt8] {
    let lo = max(from, start)
    let hi = min(to, end)
    guard lo < hi else { return [] }
    let first = (head + Int(lo - start)) % capacity
    let length = Int(hi - lo)
    if first + length <= capacity { return Array(storage[first..<(first + length)]) }
    return Array(storage[first..<capacity]) + Array(storage[0..<(first + length - capacity)])
  }
}

/// Where the VM's current run begins in `<vm>/console.log`, which spans every run: the backend
/// records the log's size in `<vm>/console.start` just before it launches the engine, and
/// `vm_serial` reads and waits from there unless told otherwise.
public enum ConsoleRun {
  static func file(_ vmDirectory: URL) -> URL { vmDirectory.appending(path: "console.start") }

  /// Records the console log's current size (0 when there is none) as the run's start.
  public static func markStart(vmDirectory: URL) {
    let size =
      ((try? FileManager.default.attributesOfItem(
        atPath: vmDirectory.appending(path: "console.log").path))?[.size] as? NSNumber)?
      .uint64Value ?? 0
    try? Data("\(size)\n".utf8).write(to: file(vmDirectory), options: .atomic)
  }

  /// The offset where the current run's output begins, or 0 when none was recorded.
  public static func start(vmDirectory: URL) -> UInt64 {
    (try? String(contentsOf: file(vmDirectory), encoding: .utf8))
      .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
  }
}

/// The engine's console log, opened read-only (created empty if the engine has not yet) and read by
/// offset. The descriptor is closed when the last reference goes.
final class ConsoleFile: Sendable {
  let url: URL
  private let fd: Int32

  init(url: URL) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fd = Darwin.open(url.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else {
      throw VMLabError(
        code: .internal, message: "Could not open the console log.",
        hint: "Check permissions on \(url.path).",
        data: ["path": .string(url.path), "errno": .number(Double(errno))])
    }
  }

  deinit { Darwin.close(fd) }

  /// The file's size now.
  var size: UInt64 {
    var info = stat()
    return fstat(fd, &info) == 0 ? UInt64(info.st_size) : 0
  }

  /// The bytes in `[from, to)` that the file holds.
  func read(from: UInt64, to: UInt64) -> [UInt8] {
    guard from < to else { return [] }
    var bytes = [UInt8](repeating: 0, count: Int(to - from))
    var got = 0
    while got < bytes.count {
      let n = bytes[got...].withUnsafeMutableBytes {
        pread(fd, $0.baseAddress, $0.count, off_t(from) + off_t(got))
      }
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { break }
      got += n
    }
    return Array(bytes[0..<got])
  }
}

/// `serial.log`, appended with `O_APPEND` and rotated to `serial.log.1` past `rotateBytes`.
struct SerialLog {
  let url: URL
  let rotateBytes: UInt64
  private var fd: Int32 = -1
  private var size: UInt64 = 0

  init(url: URL, rotateBytes: UInt64) {
    self.url = url
    self.rotateBytes = rotateBytes
  }

  var rotatedURL: URL {
    url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".1")
  }

  mutating func open() throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else {
      throw VMLabError(
        code: .internal, message: "Could not open the serial log.",
        hint: "Check permissions on \(url.path).",
        data: ["path": .string(url.path), "errno": .number(Double(errno))])
    }
    var info = stat()
    size = fstat(fd, &info) == 0 ? UInt64(info.st_size) : 0
  }

  mutating func write(_ bytes: [UInt8]) {
    guard fd >= 0 else { return }
    if size > 0, size + UInt64(bytes.count) > rotateBytes { rotate() }
    var written = 0
    while written < bytes.count {
      let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return }
      written += n
    }
    size += UInt64(written)
  }

  private mutating func rotate() {
    Darwin.close(fd)
    _ = Darwin.rename(url.path, rotatedURL.path)
    fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    size = 0
  }

  mutating func close() {
    if fd >= 0 { Darwin.close(fd) }
    fd = -1
  }
}

/// The connected socket's descriptor, closed exactly once (by the reader thread when it exits).
/// Writes, shutdown and close take `lock` only around each system call, never across a wait for
/// the guest to read (`SocketSend`), so none touches a reused descriptor and shutdown always
/// proceeds; `writeLock` keeps whole writes from interleaving.
final class SocketBox: @unchecked Sendable {
  private let lock = NSLock()
  private let writeLock = NSLock()
  private var fd: Int32
  private var shut = false

  init(fd: Int32) { self.fd = fd }

  func write(_ bytes: [UInt8], path: String, stall: Duration) throws {
    writeLock.lock()
    defer { writeLock.unlock() }
    do throws(SocketSend.Failure) {
      try SocketSend.sendAll(bytes, lock: lock, stall: stall) {
        fd >= 0 && !shut ? fd : nil
      }
    } catch .stalled(let sent) {
      throw VMLabError(
        code: .timeout,
        message:
          "The guest stopped reading the serial port: \(sent) of \(bytes.count) bytes were sent.",
        hint: "The guest may be paused or hung; check its state, or send less at once.",
        data: [
          "socket": .string(path), "sent": .number(Double(sent)),
          "bytes": .number(Double(bytes.count)),
        ])
    } catch .closed {
      throw VMLabError(
        code: .guestUnreachable, message: "The serial socket closed during the write.",
        hint: "The guest may have stopped; check its state.", data: ["socket": .string(path)])
    } catch .failed(let code) {
      throw VMLabError(
        code: .guestUnreachable, message: "Writing to the serial socket failed.",
        hint: "The guest may have stopped; check its state.",
        data: ["socket": .string(path), "errno": .number(Double(code))])
    }
  }

  /// Wakes the reader's blocking `read` with end of file.
  func shutdown() {
    lock.lock()
    defer { lock.unlock() }
    shut = true
    if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    if fd >= 0 { Darwin.close(fd) }
    fd = -1
  }
}

/// `AF_UNIX` stream connect, kept here because Core depends on no other vmlab module.
enum SerialSocket {
  struct ConnectError: Error {
    var errno: Int32
    var retryable: Bool { errno == ENOENT || errno == ECONNREFUSED }
  }

  static func connect(path: String) throws -> Int32 {
    var addr = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      throw VMLabError.invalidRequest(
        field: "socket", reason: "socket path is \(bytes.count) bytes; the limit is 103",
        hint: "Use a shorter VMLAB_HOME.")
    }
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: bytes)
      buf[bytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ConnectError(errno: errno) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0 else {
      let code = errno
      Darwin.close(fd)
      throw ConnectError(errno: code)
    }
    return fd
  }
}
