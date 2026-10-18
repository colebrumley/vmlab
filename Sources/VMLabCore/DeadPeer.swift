import Foundation
import Synchronization

/// Dead-peer detection on the engine sockets (R-1101, Appendix G: 5 s). A peer is dead when it
/// owes an answer and has sent nothing for `window`: QMP while a command or keepalive probe is
/// outstanding, RFB after a forced update request, GDB while a packet waits for its ack or reply,
/// the VZ control socket while a status probe waits. The client that sees it fails what is pending
/// with `DeadPeer.error`, closes its connection and reports the reason; the VM is then marked
/// `broken` (`Store.markBroken`), from which `vm_lifecycle kill` always works.
public enum DeadPeer {
  /// How long a peer that owes an answer may stay silent (Appendix G).
  public static let window: Duration = .seconds(5)
  /// How often an idle connection is probed, so a silent peer is noticed within `window`.
  public static let probeInterval: Duration = .seconds(1)

  /// `guest_unreachable` with `data.deadPeer: true`, the channel, the endpoint and the reason.
  public static func error(
    channel: String, endpoint: String, reason: String, vm: String? = nil
  ) -> VMLabError {
    var data: [String: JSONValue] = [
      "deadPeer": .bool(true), "channel": .string(channel), "endpoint": .string(endpoint),
      "reason": .string(reason),
    ]
    if let vm { data["vm"] = .string(vm) }
    return VMLabError(
      code: .guestUnreachable,
      message: "The \(channel) peer at \(endpoint) stopped answering: \(reason)",
      hint:
        "The engine process is hung; vmlab marks the VM broken. Use vm_lifecycle kill, then "
        + "start it again.",
      data: data)
  }

  /// Whether `error` is a dead-peer refusal from `error(channel:endpoint:reason:vm:)`.
  public static func isDeadPeer(_ error: VMLabError) -> Bool {
    error.code == .guestUnreachable && error.data["deadPeer"] == .bool(true)
  }

  /// The reason line a dead-peer error carries, for the record.
  public static func reason(of error: VMLabError) -> String {
    let channel = error.data["channel"]?.stringValue ?? "engine"
    let reason = error.data["reason"]?.stringValue ?? error.message
    return "\(channel): \(reason)"
  }

  /// "Silent for 5.0 s while waiting for X".
  public static func silence(_ duration: Duration, waitingFor what: String) -> String {
    let seconds =
      Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
    return "no answer for \(String(format: "%.1f", seconds)) s while waiting for \(what)"
  }
}

/// When a connection last heard from its peer and since when the peer has owed an answer. The
/// reader calls `received()`, the writer `awaiting(_:)` before sending something that must be
/// answered, and the watchdog asks `overdue(window:)`.
public final class PeerClock: Sendable {
  private struct State {
    var lastReceived: ContinuousClock.Instant
    /// Since when the peer owes an answer, and for what; nil when it owes none.
    var owed: (since: ContinuousClock.Instant, what: String)?
  }

  private let state: Mutex<State>

  public init(now: ContinuousClock.Instant = .now) {
    state = Mutex(State(lastReceived: now, owed: nil))
  }

  /// Bytes arrived: the peer is alive and owes nothing more for now.
  public func received(at now: ContinuousClock.Instant = .now) {
    state.withLock {
      $0.lastReceived = now
      $0.owed = nil
    }
  }

  /// Something that must be answered was sent; the earliest outstanding debt is kept.
  public func awaiting(_ what: String, at now: ContinuousClock.Instant = .now) {
    state.withLock { if $0.owed == nil { $0.owed = (now, what) } }
  }

  /// Nothing is owed any more (the work that expected an answer was abandoned).
  public func settle() { state.withLock { $0.owed = nil } }

  /// An outstanding debt starts over from `now`: the peer was excused meanwhile (it is busy with
  /// a long command another client sent), so its silence until now does not count.
  public func postpone(at now: ContinuousClock.Instant = .now) {
    state.withLock { if let owed = $0.owed { $0.owed = (now, owed.what) } }
  }

  /// How long since anything arrived.
  public func idle(at now: ContinuousClock.Instant = .now) -> Duration {
    state.withLock { now - $0.lastReceived }
  }

  /// Whether an answer is owed at all.
  public var isOwed: Bool { state.withLock { $0.owed != nil } }

  /// The dead-peer reason when an answer has been owed for `window` or longer, else nil.
  public func overdue(window: Duration, at now: ContinuousClock.Instant = .now) -> String? {
    state.withLock { state -> String? in
      guard let owed = state.owed, now - owed.since >= window else { return nil }
      return DeadPeer.silence(now - owed.since, waitingFor: owed.what)
    }
  }
}

extension Store {
  /// Marks broken the live VM whose GDB stub is `endpoint` (R-1101: the GDB client's dead-peer
  /// handler knows only the stub). Returns whether one was marked.
  @discardableResult
  public func markBroken(gdbEndpoint endpoint: GDBEndpoint, reason: String) async -> Bool {
    let records = (try? list().records) ?? []
    guard
      let record = records.first(where: {
        $0.state.isLive && $0.runtime?.gdbEndpoint.flatMap(GDBEndpoint.init(runtime:)) == endpoint
      })
    else { return false }
    return await markBroken(id: record.id, reason: reason)
  }

  /// Marks a running or paused VM `broken` with `reason` (R-1101), under its lock, and logs a
  /// `lifecycle` warning. Returns false when the VM is gone or in another state, which it leaves
  /// as it is (a VM stopped meanwhile is not broken).
  @discardableResult
  public func markBroken(id: String, reason: String) async -> Bool {
    var from: VMState?
    do {
      try update(id: id) { (record: inout VMRecord) throws(VMLabError) in
        guard record.state.isLive else { return }
        from = record.state
        record.state = .broken
        record.brokenReason = reason
      }
    } catch {
      return false
    }
    guard let from else { return false }
    let log = EventLog(vmDirectory: directory(of: id))
    try? await log.append(
      .lifecycle, "\(from.rawValue) -> broken: \(reason)", level: .warning)
    return true
  }
}
