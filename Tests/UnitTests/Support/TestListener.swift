import Darwin
import Foundation

/// A listening socket that fake servers accept on from threads of their own and that the test
/// closes from another. Darwin's `close` does not wake a thread blocked in `accept`, and a thread
/// that goes back to `accept` after the owner closed the listener uses a number that another
/// test (they run in parallel, in one process) may since have been given, and steals its
/// connections. So `accept` waits in `poll` beside a wake pipe, and the listener and the pipe are
/// closed by whichever of `close()` and the last `accept()` in progress ends last: never twice,
/// never while a thread still uses the number.
final class TestListener: @unchecked Sendable {
  private let fd: Int32
  private let wakeRead: Int32
  private let wakeWrite: Int32
  private let lock = NSLock()
  private var closing = false
  private var accepting = 0
  private var released = false

  /// Takes ownership of `fd`, a socket already bound and listening.
  init(_ fd: Int32) {
    self.fd = fd
    var ends: [Int32] = [-1, -1]
    precondition(pipe(&ends) == 0, "pipe: \(errno)")
    (wakeRead, wakeWrite) = (ends[0], ends[1])
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
  }

  deinit { close() }

  /// The next connection (a blocking socket the caller owns), or nil once `close()` was called.
  func accept() -> Int32? {
    let entered = lock.withLock {
      if !closing { accepting += 1 }
      return !closing
    }
    guard entered else { return nil }
    defer {
      lock.withLock {
        accepting -= 1
        releaseIfDone()
      }
    }
    while true {
      var fds = [
        pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
      ]
      guard poll(&fds, 2, -1) >= 0 else {
        if errno == EINTR { continue }
        return nil
      }
      // The wake byte is never drained, so every thread in `accept` sees it.
      if fds[1].revents != 0 { return nil }
      let connection = Darwin.accept(fd, nil, nil)
      if connection >= 0 {
        // Accepted sockets inherit the listener's O_NONBLOCK on Darwin.
        _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
        return connection
      }
      if errno == EAGAIN || errno == EINTR || errno == ECONNABORTED { continue }
      return nil
    }
  }

  /// Ends every `accept`, now and later; the listener closes once none is in progress.
  func close() {
    lock.withLock {
      guard !closing else { return }
      closing = true
      var byte: UInt8 = 1
      _ = write(wakeWrite, &byte, 1)
      releaseIfDone()
    }
  }

  /// Under `lock`.
  private func releaseIfDone() {
    guard closing, accepting == 0, !released else { return }
    released = true
    for descriptor in [fd, wakeRead, wakeWrite] { Darwin.close(descriptor) }
  }
}
