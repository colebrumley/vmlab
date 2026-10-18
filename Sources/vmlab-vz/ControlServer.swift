import Foundation
import Logging
import VMLabCore
import VMLabVZ

/// Serves `control.sock`: one thread accepts, one thread per connection reads request lines and
/// answers each in order. Requests run on the main queue, where the machine lives.
final class ControlServer: Sendable {
  let listenFD: Int32
  let handler: @Sendable (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) -> Void
  let logger = Logger(label: "vmlab-vz.control")

  init(
    path: String,
    handler:
      @escaping @Sendable (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) ->
      Void
  ) throws(UnixStream.Failure) {
    unlink(path)
    listenFD = try UnixStream.listen(path: path)
    self.handler = handler
  }

  func start() {
    Thread.detachNewThread { [self] in acceptLoop() }
  }

  private func acceptLoop() {
    while true {
      let fd = accept(listenFD, nil, nil)
      if fd < 0 {
        if errno == EINTR || errno == ECONNABORTED { continue }
        logger.error("accept failed: \(String(cString: strerror(errno)))")
        return
      }
      var on: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
      Thread.detachNewThread { [self] in serve(fd) }
    }
  }

  private func serve(_ fd: Int32) {
    defer { close(fd) }
    var buffer = LineBuffer()
    while true {
      let bytes: [UInt8]
      do { bytes = try UnixStream.read(fd) } catch { return }
      if bytes.isEmpty { return }
      let lines: [Data]
      do { lines = try buffer.feed(bytes) } catch {
        reply(.failure(error), to: fd)
        return
      }
      for line in lines where !line.isEmpty {
        let response: ControlResponse
        do {
          response = answer(try ControlCodec.decodeRequest(line))
        } catch {
          response = .failure(error)
        }
        guard reply(response, to: fd) else { return }
      }
    }
  }

  /// Runs `request` through the handler and waits for its reply.
  private func answer(_ request: ControlRequest) -> ControlResponse {
    let box = ReplyBox()
    let handler = handler
    handler(request) { box.set($0) }
    return box.wait()
  }

  @discardableResult
  private func reply(_ response: ControlResponse, to fd: Int32) -> Bool {
    do {
      try UnixStream.writeAll(fd, try ControlCodec.line(response))
      return true
    } catch {
      return false
    }
  }
}

/// One reply handed from the main queue to a connection thread.
private final class ReplyBox: @unchecked Sendable {
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private var value: ControlResponse?

  func set(_ response: ControlResponse) {
    lock.lock()
    let first = value == nil
    if first { value = response }
    lock.unlock()
    if first { ready.signal() }
  }

  func wait() -> ControlResponse {
    ready.wait()
    lock.lock()
    defer { lock.unlock() }
    return value!
  }
}
