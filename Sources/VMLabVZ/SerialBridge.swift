import Foundation
import VMLabCore

/// The runner's end of `<vm>/serial.sock` (R-602): a unix stream socket carrying the guest's
/// virtio console byte for byte, as QEMU's `-serial unix:...,server,wait=off` does (R-303), so the
/// one `SerialChannel` in Core reads both engines.
///
/// Wire behaviour, matching QEMU's socket chardev: one client at a time; guest output goes to the
/// connected client unchanged, and bytes the client sends go to the guest unchanged. A second
/// client waits in the listen backlog until the first disconnects. One difference, so a channel
/// that connects after the guest started still sees boot from the first byte: output produced
/// while no client is connected is kept (the last `backlogCapacity` bytes) and sent to the next
/// client before anything else, where QEMU would drop it.
public final class SerialBridge: @unchecked Sendable {
  /// How much output made while nobody is connected is kept for the next client.
  public static let backlogCapacity = 1 << 20
  /// A client that does not take output for this long is dropped, so a stuck client never stalls
  /// the guest's console.
  public static let sendTimeout: Duration = .seconds(2)

  public let path: String
  private let listenFD: Int32
  private let guestInput: Int32
  private let capacity: Int
  private let lock = NSLock()
  private var client: Int32 = -1
  private var pending: [UInt8] = []
  /// Wakes the accept loop for `stop` (Darwin's `close` does not wake a blocked `accept`).
  private let wakeRead: Int32
  private let wakeWrite: Int32
  private var started = false
  private var stopped = false
  private let loopEnded = DispatchSemaphore(value: 0)

  /// Listens at `path` (replacing a stale socket file); client bytes are written to `guestInput`,
  /// the write end of the console's input pipe, which the caller keeps open until `stop` returns.
  /// Nothing is accepted until `start`.
  public init(
    path: String, guestInput: Int32, backlogCapacity: Int = SerialBridge.backlogCapacity
  ) throws(UnixStream.Failure) {
    unlink(path)
    let listenFD = try UnixStream.listen(path: path, backlog: 4)
    var ends: [Int32] = [-1, -1]
    guard pipe(&ends) == 0 else {
      let code = errno
      close(listenFD)
      throw UnixStream.Failure(call: "pipe", errno: code)
    }
    for fd in ends { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    // Non-blocking, so a connection that goes between `poll` and `accept` cannot hold the loop.
    _ = fcntl(listenFD, F_SETFL, fcntl(listenFD, F_GETFL) | O_NONBLOCK)
    self.listenFD = listenFD
    (wakeRead, wakeWrite) = (ends[0], ends[1])
    self.path = path
    self.guestInput = guestInput
    self.capacity = max(1, backlogCapacity)
  }

  /// Starts accepting clients on a thread of its own.
  public func start() {
    let run = lock.withLock {
      defer { started = true }
      return !started && !stopped
    }
    guard run else { return }
    Thread.detachNewThread { [self] in acceptLoop() }
  }

  /// Drops the client, ends the accept loop and closes the listener. When it returns the bridge
  /// no longer touches `guestInput`. Safe to call more than once.
  public func stop() {
    let (first, running) = lock.withLock {
      defer { stopped = true }
      if !stopped, client >= 0 {
        _ = Darwin.shutdown(client, SHUT_RDWR)
        client = -1
      }
      return (!stopped, started)
    }
    guard first else { return }
    if running {
      var byte: UInt8 = 1
      _ = write(wakeWrite, &byte, 1)
      loopEnded.wait()
    }
    for fd in [listenFD, wakeRead, wakeWrite] { close(fd) }
  }

  /// Hands the bridge guest output (from any thread): to the client when one is connected, else
  /// into the backlog.
  public func guestOutput(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    if client >= 0 {
      if Self.send(bytes, to: client) { return }
      // The client is gone or stuck: wake its reader, which closes it; keep the bytes.
      _ = Darwin.shutdown(client, SHUT_RDWR)
      client = -1
    }
    keep(bytes)
  }

  /// The bytes waiting for the next client (for tests).
  public var backlog: [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    return pending
  }

  /// Whether a client is connected now.
  public var hasClient: Bool {
    lock.lock()
    defer { lock.unlock() }
    return client >= 0
  }

  private func keep(_ bytes: [UInt8]) {
    pending.append(contentsOf: bytes.suffix(capacity))
    if pending.count > capacity { pending.removeFirst(pending.count - capacity) }
  }

  private func acceptLoop() {
    defer { loopEnded.signal() }
    while true {
      var fds = [
        pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
      ]
      guard poll(&fds, 2, -1) >= 0 else {
        if errno == EINTR { continue }
        return
      }
      if fds[1].revents != 0 { return }
      let fd = accept(listenFD, nil, nil)
      if fd < 0 {
        if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
        return
      }
      // Accepted sockets inherit the listener's O_NONBLOCK on Darwin; reads here block.
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
      var on: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
      Self.setSendTimeout(fd, Self.sendTimeout)
      lock.lock()
      if stopped {
        lock.unlock()
        close(fd)
        return
      }
      let flushed = pending.isEmpty || Self.send(pending, to: fd)
      if flushed {
        pending.removeAll()
        client = fd
      }
      lock.unlock()
      if flushed { forwardInput(from: fd) }
      lock.lock()
      if client == fd { client = -1 }
      lock.unlock()
      close(fd)
    }
  }

  /// Copies client bytes to the guest until the client disconnects (or is dropped).
  private func forwardInput(from fd: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0, errno == EINTR || errno == EAGAIN { continue }
      guard count > 0 else { return }
      var written = 0
      while written < count {
        let n = buffer[written..<count].withUnsafeBytes {
          Darwin.write(guestInput, $0.baseAddress, $0.count)
        }
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { return }
        written += n
      }
    }
  }

  private static func send(_ bytes: [UInt8], to fd: Int32) -> Bool {
    var written = 0
    while written < bytes.count {
      let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if n < 0, errno == EINTR { continue }
      guard n > 0 else { return false }
      written += n
    }
    return true
  }

  /// Bounds blocking writes only; reads (waiting for the client to type) stay unbounded.
  private static func setSendTimeout(_ fd: Int32, _ timeout: Duration) {
    let (seconds, attoseconds) = timeout.components
    var value = timeval(
      tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
  }
}
