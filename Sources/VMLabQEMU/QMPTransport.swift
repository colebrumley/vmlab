import Darwin
import Foundation
import VMLabCore

/// A line-oriented byte stream to a QMP server. Each line is one JSON object.
public protocol QMPTransport: Sendable {
  /// Every line received, without its terminator; finishes when the peer closes. Iterated once.
  var lines: AsyncStream<Data> { get }
  func send(_ line: Data) async throws
  func close() async
}

/// QMP over a unix stream socket (`-qmp unix:<vm>/qmp.sock,server,wait=off`). A dedicated thread
/// does the blocking reads, so a quiet guest never holds a Swift concurrency thread. The descriptor
/// is closed once, by the reader, after `close()` shuts the socket down or the peer goes away.
public final class UnixQMPTransport: QMPTransport, @unchecked Sendable {
  public let path: String
  public let lines: AsyncStream<Data>
  /// How long a send waits for QEMU to take a byte before it fails.
  public let writeStall: Duration
  private let state: State
  /// Keeps whole lines from interleaving when sends overlap.
  private let writeLock = NSLock()

  /// The descriptor and whether it may still be used; guarded by `lock`.
  private final class State: @unchecked Sendable {
    let fd: Int32
    let lock = NSLock()
    /// False once the reader has closed the descriptor (it may then be reused by anything).
    var fdOpen = true
    var shutDown = false
    init(fd: Int32) { self.fd = fd }
  }

  /// Connects to `path`, retrying while the socket is absent or refuses, until `timeout`.
  public static func connect(
    path: String, timeout: Duration = .seconds(5), writeStall: Duration = .seconds(10)
  ) async throws(VMLabError) -> UnixQMPTransport {
    let deadline = ContinuousClock.now + timeout
    while true {
      switch UnixSocket.connect(path: path) {
      case .success(let fd):
        return UnixQMPTransport(path: path, fd: fd, writeStall: writeStall)
      case .failure(let err) where err.retryable && ContinuousClock.now < deadline:
        try? await Task.sleep(for: .milliseconds(50))
      case .failure(let err):
        throw VMLabError(
          code: .guestUnreachable, message: "The QMP socket did not accept a connection.",
          hint: "Check that the guest's QEMU process is running and owns \(path).",
          data: [
            "tried": .string(path), "errno": .number(Double(err.errno)),
            "error": .string(String(cString: strerror(err.errno))),
          ])
      }
    }
  }

  private init(path: String, fd: Int32, writeStall: Duration) {
    self.path = path
    self.writeStall = writeStall
    // Non-blocking, so a send never waits inside the descriptor's lock (CX-13).
    SocketSend.setNonBlocking(fd)
    let state = State(fd: fd)
    self.state = state
    var continuation: AsyncStream<Data>.Continuation!
    self.lines = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    let sink = continuation!
    let thread = Thread {
      var pending = Data()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let n = buffer.withUnsafeMutableBytes { SocketSend.read(fd, into: $0) }
        if n > 0 {
          pending.append(contentsOf: buffer[0..<n])
          while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { sink.yield(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
          }
        } else {
          break
        }
      }
      state.lock.withLock {
        state.fdOpen = false
        Darwin.close(fd)
      }
      sink.finish()
    }
    thread.name = "vmlab.qmp.reader"
    thread.start()
  }

  deinit {
    state.lock.withLock {
      guard state.fdOpen, !state.shutDown else { return }
      state.shutDown = true
      Darwin.shutdown(state.fd, SHUT_RDWR)
    }
  }

  public func send(_ line: Data) async throws {
    var bytes = [UInt8](line)
    bytes.append(0x0A)
    try await write(bytes)
  }

  /// Sends on a thread of its own, off the concurrency pool. The lock is taken only around each
  /// non-blocking `send` (`SocketSend`), so `close()` and the reader always proceed; a peer that
  /// takes no byte for `writeStall` fails the send with `timeout` (CX-13).
  private func write(_ bytes: [UInt8]) async throws {
    let (state, path, stall, writeLock) = (self.state, self.path, writeStall, self.writeLock)
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
      let thread = Thread {
        writeLock.lock()
        defer { writeLock.unlock() }
        do throws(SocketSend.Failure) {
          try SocketSend.sendAll(bytes, lock: state.lock, stall: stall) {
            state.fdOpen && !state.shutDown ? state.fd : nil
          }
          done.resume()
        } catch .stalled(let sent) {
          done.resume(
            throwing: VMLabError(
              code: .timeout,
              message: "QEMU stopped reading QMP: \(sent) of \(bytes.count) bytes were sent.",
              hint: "The guest's QEMU process may be hung; check vm_inspect.",
              data: ["tried": .string(path), "sent": .number(Double(sent))]))
        } catch {
          done.resume(throwing: Self.closedError(path))
        }
      }
      thread.name = "vmlab.qmp.writer"
      thread.start()
    }
  }

  public func close() async {
    let state = self.state
    state.lock.withLock {
      guard state.fdOpen, !state.shutDown else { return }
      state.shutDown = true
      Darwin.shutdown(state.fd, SHUT_RDWR)
    }
  }

  static func closedError(_ path: String) -> VMLabError {
    VMLabError(
      code: .guestUnreachable, message: "The QMP connection is closed.",
      hint: "The guest's QEMU process may have exited; check vm_inspect.",
      data: ["tried": .string(path)])
  }
}

/// `connect(2)` to a unix stream socket path, with `SO_NOSIGPIPE` set.
enum UnixSocket {
  struct ConnectError: Error {
    var errno: Int32
    /// The socket is not there yet or not listening yet.
    var retryable: Bool { errno == ENOENT || errno == ECONNREFUSED || errno == EAGAIN }
  }

  static func connect(path: String) -> Result<Int32, ConnectError> {
    var addr = sockaddr_un()
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      return .failure(ConnectError(errno: ENAMETOOLONG))
    }
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: path.utf8)
      buf[path.utf8.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failure(ConnectError(errno: errno)) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0 else {
      let err = errno
      Darwin.close(fd)
      return .failure(ConnectError(errno: err))
    }
    return .success(fd)
  }
}
