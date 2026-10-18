import Darwin
import Foundation

/// Writes all of a buffer to a stream socket that another thread may shut down or close, without
/// ever blocking while holding the lock that guards the descriptor (CX-13). The descriptor must be
/// non-blocking (`setNonBlocking`; `MSG_DONTWAIT` alone still blocks on a macOS unix socket), and
/// its reader then reads with `read(_:into:)`. Each attempt is a `send` under `lock`; while the peer's buffer is full the writer waits for
/// `POLLOUT` outside the lock, in slices of at most 50 ms, so a `shutdown` or `close` taken under
/// the same lock always proceeds, and a writer that sees no progress for `stall` gives up. A peer
/// that stopped reading (a paused guest, a stopped agent) therefore costs at most `stall`.
public enum SocketSend {
  public enum Failure: Error, Sendable, Equatable {
    /// `descriptor` returned nil: the socket was shut down or closed.
    case closed
    /// `send` failed with this errno.
    case failed(errno: Int32)
    /// No byte went for the stall timeout; `sent` bytes had gone before it.
    case stalled(sent: Int)
  }

  private enum Attempt {
    case closed
    case sent(Int)
    case wouldBlock(Int32)
    case failed(Int32)
  }

  /// Sets `O_NONBLOCK` on `fd`. It applies to every user of the descriptor, readers included.
  public static func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
  }

  /// A blocking-style `read` of a non-blocking descriptor: waits in `poll` for input (or end of
  /// file, or a `shutdown`) whenever none is there. Returns what `read` returned, never with
  /// `EAGAIN` or `EINTR`.
  public static func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    while true {
      let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
      if n >= 0 { return n }
      switch errno {
      case EINTR:
        continue
      case EAGAIN:
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&entry, 1, -1)
      default:
        return n
      }
    }
  }

  /// Sends `bytes`. `descriptor` runs under `lock` and gives the descriptor, or nil once it may no
  /// longer be used. Call it off the Swift concurrency pool: it can wait up to `stall`.
  public static func sendAll(
    _ bytes: [UInt8], lock: NSLock, stall: Duration, descriptor: () -> Int32?
  ) throws(Failure) {
    var sent = 0
    var deadline = ContinuousClock.now + stall
    while sent < bytes.count {
      let attempt: Attempt = lock.withLock {
        guard let fd = descriptor() else { return .closed }
        let n = bytes[sent...].withUnsafeBytes {
          Darwin.send(fd, $0.baseAddress, $0.count, MSG_DONTWAIT)
        }
        if n >= 0 { return .sent(n) }
        let code = errno
        return code == EAGAIN || code == EINTR ? .wouldBlock(fd) : .failed(code)
      }
      switch attempt {
      case .closed:
        throw .closed
      case .failed(let code):
        throw .failed(errno: code)
      case .sent(let n):
        sent += n
        deadline = ContinuousClock.now + stall
      case .wouldBlock(let fd):
        let left = deadline - ContinuousClock.now
        guard left > .zero else { throw .stalled(sent: sent) }
        // Outside the lock: the descriptor may be closed (POLLNVAL) or even reused meanwhile,
        // which costs at most one slice before the next attempt sees it is gone.
        var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let slice = min(left, .milliseconds(50))
        _ = poll(&entry, 1, Int32(max(1, slice / .milliseconds(1))))
      }
    }
  }
}
