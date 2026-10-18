import Darwin
import Foundation

/// Proves that an API waits off Swift's cooperative pool, which has one thread per CPU: run it in
/// more tasks than the pool has threads, against a peer that never answers, and time a trivial
/// task meanwhile. An API that blocks a pool thread holds every one of them, and the trivial task
/// then waits for the peer's timeout.
enum PoolSaturation {
  /// More blocked callers than the pool has threads.
  static var width: Int { ProcessInfo.processInfo.activeProcessorCount * 2 }

  /// How long a peer that never answers holds each caller; a pool held for this long fails
  /// `budget` by a wide margin.
  static let hold = Duration.seconds(6)

  /// What a sleep of 200 ms and a trivial task may take while `width` callers wait. Generous:
  /// when a whole suite starts at once its first second or two queue every task behind a
  /// thousand others (measured with blockers that do nothing), which is not what is proved here.
  static let budget = Duration.seconds(3)

  /// Runs `blocker` in `width` tasks at once and returns how long, beyond a 200 ms sleep, a
  /// trivial task took to run meanwhile; returns after every blocker has ended. The probe runs at
  /// the default priority on purpose: a higher one gets a thread of its own even when every
  /// default one is blocked, and would prove nothing.
  static func latency(
    width: Int = width, _ blocker: @escaping @Sendable (Int) async -> Void
  ) async -> Duration {
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<width { group.addTask { await blocker(index) } }
      let clock = ContinuousClock()
      let start = clock.now
      try? await Task.sleep(for: .milliseconds(200))
      await Task.detached { _ = 1 }.value
      let elapsed = clock.now - start - .milliseconds(200)
      await group.waitForAll()
      return elapsed
    }
  }

  /// A loopback TCP listener that accepts every connection, never reads, and closes each after
  /// `hold`, from threads of its own.
  final class SilentTCPListener: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32

    init(hold: Duration = PoolSaturation.hold) throws {
      let server = socket(AF_INET, SOCK_STREAM, 0)
      listener = server
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      address.sin_port = 0
      var size = socklen_t(MemoryLayout<sockaddr_in>.size)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, size) }
      }
      guard bound == 0, listen(server, 128) == 0 else {
        close(server)
        throw POSIXError(.EADDRINUSE)
      }
      _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &size) }
      }
      port = UInt16(bigEndian: address.sin_port)
      PoolSaturation.acceptSilently(server, hold: hold)
    }

    deinit {
      shutdown(listener, SHUT_RDWR)
      close(listener)
    }
  }

  /// A unix stream listener at a fresh path that accepts every connection, never answers, and
  /// closes each after `hold`.
  final class SilentUnixListener: @unchecked Sendable {
    let path: String
    private let listener: Int32

    init(hold: Duration = PoolSaturation.hold) throws {
      let path = "/tmp/vmlab-pool-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
      self.path = path
      unlink(path)
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: Array(path.utf8))
        raw[path.utf8.count] = 0
      }
      let server = socket(AF_UNIX, SOCK_STREAM, 0)
      listener = server
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, listen(server, 128) == 0 else {
        close(server)
        throw POSIXError(.EADDRINUSE)
      }
      PoolSaturation.acceptSilently(server, hold: hold)
    }

    deinit {
      unlink(path)
      shutdown(listener, SHUT_RDWR)
      close(listener)
    }
  }

  /// Accepts on `server` until it is closed; each connection is closed `hold` after its accept.
  private static func acceptSilently(_ server: Int32, hold: Duration) {
    let micros = useconds_t(
      clamping: hold.components.seconds * 1_000_000 + hold.components.attoseconds
        / 1_000_000_000_000)
    Thread.detachNewThread {
      while true {
        let connection = accept(server, nil, nil)
        if connection < 0 {
          if errno == EINTR { continue }
          return
        }
        Thread.detachNewThread {
          usleep(micros)
          close(connection)
        }
      }
    }
  }
}
