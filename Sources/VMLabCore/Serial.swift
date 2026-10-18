import Foundation

/// Bytes read back from a serial channel. Offsets count bytes from the first byte the channel
/// received.
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
/// the `vmlab-vz` runner's bridge, R-602). A background reader appends every byte to
/// `serial.log` (rotated to `serial.log.1` past `rotateBytes`) and to a ring of the last
/// `ringCapacity` bytes, so `read`, `tail` and `wait` work on absolute byte offsets.
public actor SerialChannel {
  public static let defaultRingCapacity = 4 * 1024 * 1024
  public static let defaultRotateBytes: UInt64 = 64 * 1024 * 1024
  /// How far back `wait` re-scans on each new chunk; a match longer than this can be missed.
  static let rescanOverlap: UInt64 = 4096
  /// A line longer than this is handed to the observer in pieces.
  static let maxLineBytes = 64 * 1024

  public let socketPath: String
  public let logURL: URL
  public let ringCapacity: Int
  public let rotateBytes: UInt64

  private var ring: ByteRing
  private var log: SerialLog
  private var socket: SocketBox?
  private var readerTask: Task<Void, Never>?
  private var closed = false
  /// Every line observer, by key; key 0 is `setLineObserver`'s slot.
  private var lineObservers: [UInt64: @Sendable (SerialLine) -> Void] = [:]
  private var nextObserverKey: UInt64 = 1
  private var partialLine: [UInt8] = []
  private var partialLineStart: UInt64 = 0
  private var waiters: [UInt64: Waiter] = [:]
  private var nextWaiterID: UInt64 = 0

  private struct Waiter {
    var regex: Regex<AnyRegexOutput>
    var since: UInt64
    var scanFrom: UInt64
    var continuation: CheckedContinuation<SerialMatch, any Error>
    var timer: Task<Void, Never>?
  }

  /// A channel for the socket at `socketPath` logging to `logURL` (normally `<vm>/serial.log`).
  /// Nothing is opened until `start`.
  public init(
    socketPath: String, logURL: URL, ringCapacity: Int = SerialChannel.defaultRingCapacity,
    rotateBytes: UInt64 = SerialChannel.defaultRotateBytes
  ) {
    self.socketPath = socketPath
    self.logURL = logURL
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
      try log.open()
    } catch {
      Darwin.close(fd)
      throw error
    }
    let box = SocketBox(fd: fd)
    socket = box
    let readFD = fd
    let chunks = AsyncStream<[UInt8]> { continuation in
      let thread = Thread {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
          let n = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
          if n > 0 {
            continuation.yield(Array(buffer[0..<n]))
          } else if n < 0 && errno == EINTR {
            continue
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
    readerTask = Task { [weak self] in
      for await chunk in chunks { await self?.ingest(chunk) }
      await self?.readerFinished()
    }
  }

  /// Stops the reader and closes the socket and log. Pending waits fail with `guest_unreachable`.
  public func stop() async {
    closed = true
    socket?.shutdown()
    await readerTask?.value
    readerFinished()
  }

  /// The offset after the last byte received.
  public var endOffset: UInt64 { ring.end }

  /// The offset of the oldest byte still in the ring.
  public var startOffset: UInt64 { ring.start }

  /// True while the reader is connected.
  public var isConnected: Bool { socket != nil && !closed }

  /// Bytes from `since` to the end, at most `maxBytes` of them. A `since` older than the ring
  /// starts at the oldest retained byte with `truncated` set; one past the end returns nothing.
  public func read(since: UInt64, maxBytes: Int? = nil) -> SerialRead {
    let from = min(max(since, ring.start), ring.end)
    var to = ring.end
    if let maxBytes, maxBytes >= 0 { to = min(to, from + UInt64(maxBytes)) }
    let bytes = ring.bytes(from: from, to: to)
    return SerialRead(
      text: String(decoding: bytes, as: UTF8.self), start: from, offset: to,
      truncated: since < ring.start || to < ring.end)
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
  @discardableResult
  public func write(_ text: String) throws -> UInt64 {
    guard let socket, !closed else { throw Self.unreachable(socketPath) }
    try socket.write(Array(text.utf8), path: socketPath)
    return ring.end
  }

  /// Waits until `pattern` (Swift `Regex` syntax) matches output at or after `since` (default: the
  /// current end, so only new output counts), or fails with `timeout` after `timeout`. The pattern
  /// is matched against the retained output on each new chunk, re-scanning the last 4 KB.
  public func wait(
    for pattern: String, since: UInt64? = nil, timeout: Duration
  ) async throws -> SerialMatch {
    let regex: Regex<AnyRegexOutput>
    do {
      regex = try Regex(pattern)
    } catch {
      throw VMLabError.invalidRequest(
        field: "pattern", reason: "not a valid regular expression: \(error)",
        hint: "Pass a Swift Regex pattern, for example \"login:\" or \"\\\\$ $\".")
    }
    let from = since ?? ring.end
    if let found = Self.search(regex, in: ring, from: max(from, ring.start)) { return found }
    guard !closed, socket != nil else { throw Self.unreachable(socketPath) }
    let id = nextWaiterID
    nextWaiterID += 1
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timer = Task { [weak self] in
          try? await Task.sleep(for: timeout)
          await self?.expire(id, pattern: pattern, timeout: timeout)
        }
        waiters[id] = Waiter(
          regex: regex, since: from, scanFrom: max(from, ring.start), continuation: continuation,
          timer: timer)
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  // MARK: - Reader side

  private func ingest(_ chunk: [UInt8]) {
    let chunkStart = ring.end
    ring.append(chunk)
    log.write(chunk)
    emitLines(chunk, startingAt: chunkStart)
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
    for (id, waiter) in waiters {
      let from = max(waiter.since, ring.start, waiter.scanFrom)
      if let found = Self.search(waiter.regex, in: ring, from: from) {
        waiters[id] = nil
        waiter.timer?.cancel()
        waiter.continuation.resume(returning: found)
      } else {
        let next = ring.end > Self.rescanOverlap ? ring.end - Self.rescanOverlap : 0
        waiters[id]?.scanFrom = max(waiter.since, next)
      }
    }
  }

  private func readerFinished() {
    socket = nil
    log.close()
    partialLine.removeAll()
    for (id, waiter) in waiters {
      waiters[id] = nil
      waiter.timer?.cancel()
      waiter.continuation.resume(throwing: Self.unreachable(socketPath))
    }
  }

  /// How much of the output a timed-out wait returns.
  static let timeoutTextBytes: UInt64 = 4096

  private func expire(_ id: UInt64, pattern: String, timeout: Duration) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    // Partial data (R-1101): what the guest printed while the wait ran, its last 4 KB at most.
    let end = ring.end
    let from = max(
      waiter.since, ring.start, end >= Self.timeoutTextBytes ? end - Self.timeoutTextBytes : 0)
    let seen = read(since: from)
    waiter.continuation.resume(
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

  private func cancelWaiter(_ id: UInt64) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    waiter.timer?.cancel()
    waiter.continuation.resume(throwing: CancellationError())
  }

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

  /// The first match of `regex` in the ring at or after `from`, with byte offsets.
  static func search(_ regex: Regex<AnyRegexOutput>, in ring: ByteRing, from: UInt64)
    -> SerialMatch?
  {
    guard from < ring.end else { return nil }
    var bytes = ring.bytes(from: from, to: ring.end)
    // Start on a UTF-8 boundary and leave out an incomplete final sequence, so the text decodes.
    var lead = 0
    while lead < bytes.count, lead < 3, bytes[lead] & 0xC0 == 0x80 { lead += 1 }
    bytes.removeFirst(lead)
    bytes.removeLast(UTF8Tail.incompleteSuffix(bytes))
    let base = from + UInt64(lead)
    let text: String
    let utf8: Bool
    if let valid = String(validating: bytes, as: UTF8.self) {
      text = valid
      utf8 = true
    } else {
      // Latin-1: one scalar per byte, so offsets stay exact for ASCII patterns.
      text = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
      utf8 = false
    }
    guard let match = try? regex.firstMatch(in: text) else { return nil }
    func offset(_ index: String.Index) -> UInt64 {
      let distance =
        utf8
        ? text.utf8.distance(from: text.startIndex, to: index)
        : text.unicodeScalars.distance(from: text.startIndex, to: index)
      return base + UInt64(distance)
    }
    return SerialMatch(
      match: String(text[match.range]), start: offset(match.range.lowerBound),
      offset: offset(match.range.upperBound))
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

  init(capacity: Int) { storage = [UInt8](repeating: 0, count: capacity) }

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

/// The connected socket's descriptor, closed exactly once (by the reader thread when it exits),
/// with writes and shutdown taken under the same lock so none touches a reused descriptor.
final class SocketBox: @unchecked Sendable {
  private let lock = NSLock()
  private var fd: Int32

  init(fd: Int32) { self.fd = fd }

  func write(_ bytes: [UInt8], path: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var written = 0
    while written < bytes.count {
      guard fd >= 0 else { break }
      let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else {
        throw VMLabError(
          code: .guestUnreachable, message: "Writing to the serial socket failed.",
          hint: "The guest may have stopped; check its state.",
          data: ["socket": .string(path), "errno": .number(Double(errno))])
      }
      written += n
    }
    if written < bytes.count {
      throw VMLabError(
        code: .guestUnreachable, message: "The serial socket closed during the write.",
        hint: "The guest may have stopped; check its state.", data: ["socket": .string(path)])
    }
  }

  /// Wakes the reader's blocking `read` with end of file.
  func shutdown() {
    lock.lock()
    defer { lock.unlock() }
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
