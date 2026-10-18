import Darwin
import Foundation
import Synchronization

/// Runs `vm_serial wait`'s model-supplied regular expressions in `vmlab-match`, a helper process
/// the server kills at the wait's deadline. Swift `Regex` backtracks and cannot be interrupted, so
/// a pathological pattern run in-process would hold a CPU core after its wait ended; a process can
/// be killed. One helper serves one wait: it compiles the pattern once, then answers one window of
/// output after another over its stdin and stdout until it is killed or its stdin closes. A
/// pattern that is a plain literal (`literal(of:)`) needs no helper: the channel finds it with a
/// byte search in-process, which is linear.
///
/// The framing, every integer little-endian: the helper first writes one byte, `R`, once it runs
/// (so the server knows how long launching took). The server sends the pattern (`u32` length, UTF-8),
/// then each window (`u64` offset of its first byte, `u32` length, the bytes). The helper answers
/// each window with one byte, `0` for no match, `1` for a match followed by `u64` start, `u64`
/// end and the matched text (`u32` length, UTF-8), or `2` for a pattern that does not compile
/// followed by the reason (`u32` length, UTF-8), after which it exits.
public enum SerialMatcher {
  /// The helper's file name, installed beside `vmlab`.
  public static let executableName = "vmlab-match"
  /// The environment variable that names the helper explicitly (tests, unusual layouts).
  public static let environmentKey = "VMLAB_MATCH_HELPER"
  /// The largest window the helper reads; the channel sends at most `SerialChannel.scanWindow`.
  static let maxFrameBytes = 1 << 20

  /// Where the helper is: `VMLAB_MATCH_HELPER` when set, else `vmlab-match` beside the running
  /// executable (`vmlab serve`, the CLI, the release tarball), beside that executable with
  /// symbolic links resolved, or beside the bundle this code was linked into (the test bundle in
  /// `.build/<config>/`). Nil when none of them is an executable file.
  public static func locate(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> String? {
    if let explicit = environment[environmentKey], !explicit.isEmpty {
      return isExecutable(explicit) ? explicit : nil
    }
    var directories: [URL] = []
    if let main = Bundle.main.executableURL {
      directories.append(main.deletingLastPathComponent())
      directories.append(main.resolvingSymlinksInPath().deletingLastPathComponent())
    }
    directories.append(Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent())
    for directory in directories {
      let path = directory.appending(path: executableName).path
      if isExecutable(path) { return path }
    }
    return nil
  }

  /// The helper path `SerialChannel` uses by default, found once per process.
  public static let defaultPath: String? = locate()

  /// The `engine_error` for a helper that cannot be found or run.
  static func missing(_ path: String?, detail: String? = nil) -> VMLabError {
    VMLabError(
      code: .engineError,
      message: "The serial pattern matcher \(executableName) "
        + (path == nil ? "was not found." : "could not run\(detail.map { ": \($0)" } ?? ".")"),
      hint: "Install \(executableName) next to vmlab (the release tarball ships it), "
        + "or set \(environmentKey) to its path.",
      data: ["tool": .string(executableName), "path": path.map(JSONValue.string) ?? .null])
  }

  // MARK: - The helper's side

  /// The helper's loop over `input` and `output`; returns its exit status. 0 once the input ends.
  public static func serve(input: Int32 = 0, output: Int32 = 1) -> Int32 {
    guard writeAll(output, [readyByte]) else { return 1 }
    guard let length = readUInt32(input), Int(length) <= maxFrameBytes,
      let patternBytes = readExact(input, Int(length))
    else { return 1 }
    let pattern = String(decoding: patternBytes, as: UTF8.self)
    let regex: Regex<AnyRegexOutput>
    do {
      regex = try Regex(pattern)
    } catch {
      var reply: [UInt8] = [2]
      appendString("\(error)", to: &reply)
      _ = writeAll(output, reply)
      return 1
    }
    while true {
      guard let base = readUInt64(input) else { return 0 }
      guard let count = readUInt32(input), Int(count) <= maxFrameBytes,
        let bytes = readExact(input, Int(count))
      else { return 1 }
      var reply: [UInt8]
      if let found = search(regex, bytes: bytes, base: base) {
        reply = [1]
        appendUInt64(found.start, to: &reply)
        appendUInt64(found.offset, to: &reply)
        appendString(found.match, to: &reply)
      } else {
        reply = [0]
      }
      guard writeAll(output, reply) else { return 1 }
    }
  }

  /// The byte the helper writes once it runs.
  static let readyByte = UInt8(ascii: "R")

  /// The text `pattern` matches when it is a plain literal: no regex syntax but escaped
  /// punctuation (`\$`, `\.`, `\(`); nil otherwise. Such a pattern is matched byte for byte.
  public static func literal(of pattern: String) -> String? {
    var result = ""
    var iterator = pattern.makeIterator()
    while let c = iterator.next() {
      switch c {
      case "\\":
        guard let next = iterator.next(), next.isASCII, next.isPunctuation || next.isSymbol
        else { return nil }
        result.append(next)
      case "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}":
        return nil
      default:
        // Whitespace and letters stand for themselves; `#` and the like only matter in extended
        // syntax, which a pattern can turn on only with `(?x)`, already refused above.
        result.append(c)
      }
    }
    return result.isEmpty ? nil : result
  }

  /// The first occurrence of `literal`'s UTF-8 bytes in `bytes`, which start at offset `base`.
  public static func search(literal: [UInt8], in bytes: [UInt8], base: UInt64) -> SerialMatch? {
    guard !literal.isEmpty, bytes.count >= literal.count else { return nil }
    let index: Int? = bytes.withUnsafeBytes { haystack in
      literal.withUnsafeBytes { needle in
        guard
          let found = memmem(
            haystack.baseAddress, haystack.count, needle.baseAddress, needle.count)
        else { return nil }
        return haystack.baseAddress!.distance(to: UnsafeRawPointer(found))
      }
    }
    guard let index else { return nil }
    return SerialMatch(
      match: String(decoding: literal, as: UTF8.self), start: base + UInt64(index),
      offset: base + UInt64(index + literal.count))
  }

  /// The first match of `regex` in `bytes`, which start at offset `base`, with byte offsets.
  public static func search(_ regex: Regex<AnyRegexOutput>, bytes: [UInt8], base: UInt64)
    -> SerialMatch?
  {
    guard !bytes.isEmpty else { return nil }
    var bytes = bytes
    // Start on a UTF-8 boundary and leave out an incomplete final sequence, so the text decodes.
    var lead = 0
    while lead < bytes.count, lead < 3, bytes[lead] & 0xC0 == 0x80 { lead += 1 }
    bytes.removeFirst(lead)
    bytes.removeLast(UTF8Tail.incompleteSuffix(bytes))
    let base = base + UInt64(lead)
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

  // MARK: - Framing

  static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
    withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
  }

  static func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
    withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
  }

  static func appendString(_ string: String, to bytes: inout [UInt8]) {
    let utf8 = Array(string.utf8)
    appendUInt32(UInt32(utf8.count), to: &bytes)
    bytes.append(contentsOf: utf8)
  }

  /// Exactly `count` bytes from `fd`, or nil at end of input or on an error.
  static func readExact(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
      let n = bytes[got...].withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if n < 0, errno == EINTR { continue }
      guard n > 0 else { return nil }
      got += n
    }
    return bytes
  }

  static func readUInt32(_ fd: Int32) -> UInt32? {
    readExact(fd, 4).map { b in
      b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
  }

  static func readUInt64(_ fd: Int32) -> UInt64? {
    readExact(fd, 8).map { b in
      b.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
  }

  static func readString(_ fd: Int32) -> String? {
    guard let count = readUInt32(fd), Int(count) <= maxFrameBytes,
      let bytes = readExact(fd, Int(count))
    else { return nil }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Writes all of `bytes`; false when the peer is gone.
  static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var written = 0
    while written < bytes.count {
      let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if n < 0, errno == EINTR { continue }
      guard n > 0 else { return false }
      written += n
    }
    return true
  }

  private final class BundleToken {}
}

/// One `vmlab-match` process, launched ahead of need (a channel keeps one warm spare) or by the
/// first scan of the wait it serves. `start` and `scan` block, so they run on threads of their
/// own, never on an actor; `kill` never blocks: it sends `SIGKILL` at once, and a launch or scan in
/// progress returns `.killed` as soon as the helper's stdout closes. Foundation's `Process` reaps
/// the child. The time a scan spent waiting for the helper to start is `launchWait`, which the
/// channel adds to the wait's deadline: a busy host's spawn is not the pattern's matching time.
final class MatchHelperProcess: @unchecked Sendable {
  enum Outcome: Sendable {
    case found(SerialMatch)
    case none
    /// `kill` ended the helper (the wait is over).
    case killed
    case failed(VMLabError)
  }

  private enum State {
    case idle
    case launching
    case ready(input: Int32, output: Int32)
    case failed(VMLabError)
    case killed
  }

  let path: String
  private let condition = NSCondition()
  private var state = State.idle
  private var process: Process?
  private var toHelper: FileHandle?
  private var fromHelper: FileHandle?
  private var pattern: String?
  private var headerSent = false
  private var waitedForLaunch: Duration = .zero
  private var scanWaiting = false

  init(path: String) { self.path = path }

  /// The helper's pid once launched.
  var pid: pid_t? { locked { process?.processIdentifier } }

  /// True while the helper is being started and a scan is waiting for it.
  var scanIsWaitingForLaunch: Bool { locked { scanWaiting } }

  /// How long scans have waited for the helper to start so far.
  var launchWait: Duration { locked { waitedForLaunch } }

  /// The pattern this helper will run; set once, before its first scan.
  func assign(pattern: String) { locked { self.pattern = pattern } }

  /// Starts the helper and waits for its ready byte, unless it was started or killed already.
  func start() {
    condition.lock()
    guard case .idle = state else {
      condition.unlock()
      return
    }
    state = .launching
    condition.unlock()
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = []
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    // A write to a helper that died must fail with EPIPE, not raise SIGPIPE in the server.
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    var next: State
    do {
      try process.run()
      condition.lock()
      self.process = process
      toHelper = input.fileHandleForWriting
      fromHelper = output.fileHandleForReading
      let wasKilled: Bool
      if case .killed = state { wasKilled = true } else { wasKilled = false }
      if wasKilled { Darwin.kill(process.processIdentifier, SIGKILL) }
      condition.unlock()
      let ready = SerialMatcher.readExact(output.fileHandleForReading.fileDescriptor, 1)
      next =
        ready == [SerialMatcher.readyByte]
        ? .ready(
          input: input.fileHandleForWriting.fileDescriptor,
          output: output.fileHandleForReading.fileDescriptor)
        : .failed(SerialMatcher.missing(path, detail: "it exited at start"))
    } catch {
      next = .failed(SerialMatcher.missing(path, detail: "\(error)"))
    }
    condition.lock()
    if case .killed = state {
    } else {
      state = next
      if case .failed = next, let process = self.process, process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }
    condition.broadcast()
    condition.unlock()
  }

  /// Matches `bytes` (starting at offset `base`) in the helper, launching it first if need be.
  func scan(_ bytes: [UInt8], base: UInt64) -> Outcome {
    let fds: (input: Int32, output: Int32)
    let header: [UInt8]?
    condition.lock()
    if case .idle = state {
      condition.unlock()
      let started = ContinuousClock.now
      locked { scanWaiting = true }
      start()
      locked {
        scanWaiting = false
        waitedForLaunch += ContinuousClock.now - started
      }
      condition.lock()
    }
    if case .launching = state {
      let started = ContinuousClock.now
      scanWaiting = true
      while case .launching = state { condition.wait() }
      scanWaiting = false
      waitedForLaunch += ContinuousClock.now - started
    }
    switch state {
    case .ready(let input, let output):
      fds = (input, output)
    case .failed(let error):
      condition.unlock()
      return .failed(error)
    case .killed, .idle, .launching:
      condition.unlock()
      return .killed
    }
    if headerSent {
      header = nil
    } else {
      var bytes: [UInt8] = []
      SerialMatcher.appendString(pattern ?? "", to: &bytes)
      header = bytes
      headerSent = true
    }
    condition.unlock()
    var frame = header ?? []
    frame.reserveCapacity(frame.count + bytes.count + 12)
    SerialMatcher.appendUInt64(base, to: &frame)
    SerialMatcher.appendUInt32(UInt32(bytes.count), to: &frame)
    frame.append(contentsOf: bytes)
    guard SerialMatcher.writeAll(fds.input, frame),
      let kind = SerialMatcher.readExact(fds.output, 1)?.first
    else { return lostHelper() }
    switch kind {
    case 0:
      return .none
    case 1:
      guard let start = SerialMatcher.readUInt64(fds.output),
        let end = SerialMatcher.readUInt64(fds.output),
        let text = SerialMatcher.readString(fds.output)
      else { return lostHelper() }
      return .found(SerialMatch(match: text, start: start, offset: end))
    case 2:
      let reason = SerialMatcher.readString(fds.output) ?? "unknown"
      return .failed(
        VMLabError.invalidRequest(
          field: "pattern", reason: "not a valid regular expression: \(reason)",
          hint: "Pass a Swift Regex pattern, for example \"login:\" or \"\\\\$ $\"."))
    default:
      return lostHelper()
    }
  }

  /// Ends the helper with `SIGKILL` (or keeps it from launching). Safe to call more than once.
  func kill() {
    condition.lock()
    defer { condition.unlock() }
    state = .killed
    if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    condition.broadcast()
  }

  /// The helper's pipes broke: `.killed` when `kill` did it, else a crash, reported as such.
  private func lostHelper() -> Outcome {
    condition.lock()
    defer { condition.unlock() }
    if case .killed = state { return .killed }
    state = .killed
    if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    return .failed(
      VMLabError(
        code: .engineError, message: "The serial pattern matcher exited during a match.",
        hint: "Try the wait again; if it repeats, the pattern may exhaust the matcher's memory.",
        data: ["tool": .string(SerialMatcher.executableName), "path": .string(path)]))
  }

  private func locked<T>(_ body: () -> T) -> T {
    condition.lock()
    defer { condition.unlock() }
    return body()
  }

  deinit {
    if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
  }
}
