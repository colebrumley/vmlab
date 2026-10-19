import Darwin
import Foundation

/// Waits for "every copy is closed" instead of checking it at once. While any thread of the test
/// process is inside `posix_spawn` (other tests start fake `ssh`, `qemu` and helper processes all
/// the time), the half-made child holds a copy of every descriptor the process has open, until
/// its `exec` completes and close-on-exec drops them: milliseconds, more on a loaded host
/// (measured: 1 to 18 ms, the holder's image still the test runner's). A close is therefore seen
/// by the peer a little later, never instantly; a copy that really leaked stays open for good.
enum SpawnWindow {
  /// How long a check waits for the last copy to go; ends early once it has.
  static let grace = Duration.seconds(10)

  /// Whether the pipe or socket read end `fd` reaches end of file within `timeout`, with no data
  /// before it. Leaves `fd` non-blocking.
  static func reachesEndOfFile(_ fd: Int32, within timeout: Duration = grace) -> Bool {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let deadline = ContinuousClock.now + timeout
    while true {
      var byte: UInt8 = 0
      let n = read(fd, &byte, 1)
      if n == 0 { return true }
      if n > 0 || (errno != EAGAIN && errno != EINTR) { return false }
      guard ContinuousClock.now < deadline else { return false }
      var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      _ = poll(&entry, 1, 10)
    }
  }

  /// Whether `attempt` returns true within `timeout`, retried every millisecond.
  static func eventually(within timeout: Duration = grace, _ attempt: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !attempt() {
      guard ContinuousClock.now < deadline else { return false }
      usleep(1_000)
    }
    return true
  }
}
