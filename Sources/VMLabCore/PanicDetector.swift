import Foundation
import Logging
import Synchronization

/// The serial lines that mean a guest kernel or firmware has crashed (R-304). A line matches when
/// it contains the needle anywhere, so a kernel timestamp prefix does not hide it.
public struct PanicSignature: Sendable, Hashable {
  public var needle: String

  public init(_ needle: String) { self.needle = needle }

  public static let table: [PanicSignature] = [
    PanicSignature("Kernel panic - not syncing"),
    PanicSignature("BUG:"),
    PanicSignature("Oops:"),
    PanicSignature("general protection fault"),
    PanicSignature("Synchronous Exception"),
    PanicSignature("rcu: INFO: rcu_sched self-detected stall"),
  ]

  /// The first signature of `table` that `line` contains, or nil.
  public static func match(_ line: String, in table: [PanicSignature] = table) -> PanicSignature? {
    table.first { line.contains($0.needle) }
  }
}

/// Watches a guest's serial lines for `PanicSignature`s and appends one `panic` event per matching
/// line to the VM's event log, with the line as the message and `pattern`, `offset` (the line's
/// first byte in the serial stream) and `end` as data. Appends happen in line order on a task of
/// the detector's own; after `maxEvents` it logs one suppression notice and stays quiet, so a
/// firmware exception loop cannot flood the log.
public final class PanicDetector: Sendable {
  public static let defaultMaxEvents = 32

  public let log: EventLog
  private let continuation: AsyncStream<VMEvent>.Continuation
  private let consumer: Task<Void, Never>
  private let state: Mutex<State>

  private struct State {
    var emitted = 0
    var suppressed = false
  }

  private let table: [PanicSignature]
  private let maxEvents: Int

  public init(
    log: EventLog, table: [PanicSignature] = PanicSignature.table,
    maxEvents: Int = PanicDetector.defaultMaxEvents,
    logger: Logger = Logger(label: "vmlab.panic")
  ) {
    self.log = log
    self.table = table
    self.maxEvents = max(1, maxEvents)
    self.state = Mutex(State())
    let (stream, continuation) = AsyncStream<VMEvent>.makeStream()
    self.continuation = continuation
    self.consumer = Task {
      for await event in stream {
        do {
          try await log.append(event)
        } catch {
          logger.warning(
            "could not append a panic event",
            metadata: ["error": "\(error)", "file": "\(log.url.path)"])
        }
      }
    }
  }

  /// A detector for `<vmDirectory>/events.jsonl`.
  public convenience init(vmDirectory: URL) {
    self.init(log: EventLog(vmDirectory: vmDirectory))
  }

  deinit { continuation.finish() }

  /// Adds the detector to `channel`'s line observers (beside any others).
  public func attach(to channel: SerialChannel) async {
    await channel.addLineObserver { [self] line in observe(line) }
  }

  /// Checks one serial line; a match queues a `panic` event.
  public func observe(_ line: SerialLine) {
    guard let signature = PanicSignature.match(line.text, in: table) else { return }
    let event: VMEvent? = state.withLock { state in
      if state.emitted < maxEvents {
        state.emitted += 1
        return VMEvent(
          level: .critical, kind: .panic, message: line.text,
          data: [
            "source": .string("serial"), "pattern": .string(signature.needle),
            "offset": .number(Double(line.start)), "end": .number(Double(line.end)),
          ])
      }
      guard !state.suppressed else { return nil }
      state.suppressed = true
      return VMEvent(
        level: .warning, kind: .panic,
        message: "more than \(maxEvents) panic lines on serial; further ones are not logged",
        data: [
          "source": .string("serial"), "offset": .number(Double(line.start)),
          "suppressed": .bool(true),
        ])
    }
    if let event { continuation.yield(event) }
  }

  /// Stops accepting lines and waits until every queued event is in the log.
  public func finish() async {
    continuation.finish()
    await consumer.value
  }
}

/// QMP events the QEMU backend forwards to the event log (R-304). The backend calls
/// `EventLog.recordQMPEvent(_:data:)` for every asynchronous QMP event; the ones listed here
/// become `VMEvent`s, the rest are ignored.
public enum QMPEventLogging {
  /// The event-log entry for QMP event `name` with its `data` object, or nil when it is not logged.
  /// `GUEST_PANICKED` is a `panic`; `RESET` is a `lifecycle` event.
  public static func event(name: String, data: JSONValue?, at ts: Date = Date()) -> VMEvent? {
    var fields: [String: JSONValue] = [:]
    if case .object(let object) = data { fields = object }
    var detail: [String: JSONValue] = ["source": .string("qmp"), "event": .string(name)]
    if let data, data != .null { detail["data"] = data }
    switch name {
    case "GUEST_PANICKED":
      let action: String? = if case .string(let text) = fields["action"] { text } else { nil }
      let message =
        "guest panicked (QMP GUEST_PANICKED" + (action.map { ", action \($0)" } ?? "") + ")"
      return VMEvent(ts: ts, level: .critical, kind: .panic, message: message, data: detail)
    case "RESET":
      let reason: String? = if case .string(let text) = fields["reason"] { text } else { nil }
      let guest: Bool? = if case .bool(let flag) = fields["guest"] { flag } else { nil }
      let who = guest == true ? "by the guest" : guest == false ? "by the host" : nil
      let parts = [who, reason.map { "reason \($0)" }].compactMap { $0 }
      let message =
        "guest reset (QMP RESET" + (parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")) + ")"
      return VMEvent(ts: ts, level: .warning, kind: .lifecycle, message: message, data: detail)
    default:
      return nil
    }
  }
}

extension EventLog {
  /// Appends the event-log entry for a QMP event, if it is one vmlab logs. Returns whether
  /// anything was appended.
  @discardableResult
  public func recordQMPEvent(_ name: String, data: JSONValue?) throws -> Bool {
    guard let event = QMPEventLogging.event(name: name, data: data) else { return false }
    try append(event)
    return true
  }

  /// The most recent `panic` event in the log, or nil. A suppression notice is not a panic.
  public func latestPanic() throws -> VMEvent? {
    try read().events.last(where: Self.isPanic)
  }

  /// Whether `event` reports a crash (not the detector's suppression notice).
  public static func isPanic(_ event: VMEvent) -> Bool {
    event.kind == .panic && event.data?["suppressed"] != .bool(true)
  }
}
