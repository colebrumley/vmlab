import Foundation
import VMLabCore

/// The server's side of a `vmlab-vz` runner's control socket. Each call opens a connection, sends
/// one request line, reads one response line and closes, so a client holds no state a restarted
/// server or runner could invalidate. The blocking socket work runs off the cooperative pool.
public struct VZControlClient: Sendable, Hashable {
  public var socketPath: String

  public init(socketPath: String) {
    self.socketPath = socketPath
  }

  /// How long each command may take before `timeout`.
  public static func defaultTimeout(for command: ControlCommand) -> Duration {
    switch command {
    case .status: .seconds(5)
    case .pause, .resume, .stop, .kill, .exit: .seconds(30)
    case .save, .restore: .seconds(600)
    }
  }

  /// Sends `request`; returns the runner's success reply, throws the runner's error for `ok: false`,
  /// `guest_unreachable` when nothing answers on the socket, and `timeout` when the reply is late.
  @discardableResult
  public func send(_ request: ControlRequest, timeout: Duration? = nil) async throws(VMLabError)
    -> ControlResponse
  {
    let path = socketPath
    let limit = timeout ?? Self.defaultTimeout(for: request.command)
    let result: Result<ControlResponse, VMLabError> = await withCheckedContinuation { done in
      DispatchQueue.global().async {
        done.resume(
          returning: Result { () throws(VMLabError) in
            try Self.exchange(request, path: path, timeout: limit)
          })
      }
    }
    let response = try result.get()
    guard response.ok else {
      throw response.error
        ?? VMLabError(
          code: .engineError, message: "The VZ runner refused \(request.command.rawValue)",
          hint: "Check <vm>/vz.log.")
    }
    return response
  }

  public func status() async throws(VMLabError) -> ControlResponse {
    try await send(ControlRequest(.status))
  }

  @discardableResult public func pause() async throws(VMLabError) -> ControlResponse {
    try await send(ControlRequest(.pause))
  }

  @discardableResult public func resume() async throws(VMLabError) -> ControlResponse {
    try await send(ControlRequest(.resume))
  }

  @discardableResult public func stop() async throws(VMLabError) -> ControlResponse {
    try await send(ControlRequest(.stop))
  }

  @discardableResult public func kill() async throws(VMLabError) -> ControlResponse {
    try await send(ControlRequest(.kill))
  }

  @discardableResult public func save(to path: String) async throws(VMLabError) -> ControlResponse {
    try await send(ControlRequest(.save, path: path))
  }

  @discardableResult public func restore(from path: String) async throws(VMLabError)
    -> ControlResponse
  {
    try await send(ControlRequest(.restore, path: path))
  }

  /// Ends the runner (stopping the guest first if it runs).
  @discardableResult public func exit() async throws(VMLabError) -> ControlResponse {
    try await send(ControlRequest(.exit))
  }

  static func exchange(_ request: ControlRequest, path: String, timeout: Duration)
    throws(VMLabError) -> ControlResponse
  {
    let line = try ControlCodec.line(request)
    let fd: Int32
    do { fd = try UnixStream.connect(path: path) } catch {
      throw unreachable(path, error.description)
    }
    defer { close(fd) }
    UnixStream.setTimeout(fd, timeout)
    var buffer = LineBuffer()
    do {
      try UnixStream.writeAll(fd, line)
      while true {
        let bytes = try UnixStream.read(fd)
        guard !bytes.isEmpty else {
          throw unreachable(path, "the runner closed the connection without replying")
        }
        if let reply = try buffer.feed(bytes).first {
          return try ControlCodec.decodeResponse(reply)
        }
      }
    } catch let failure as UnixStream.Failure {
      if failure.errno == EAGAIN || failure.errno == EWOULDBLOCK {
        throw VMLabError(
          code: .timeout,
          message: "The VZ runner did not answer \(request.command.rawValue) within \(timeout)",
          hint: "Check <vm>/vz.log; retry, or kill the VM.",
          data: ["socket": .string(path), "command": .string(request.command.rawValue)])
      }
      throw unreachable(path, failure.description)
    } catch let error as VMLabError {
      throw error
    } catch {
      throw unreachable(path, "\(error)")
    }
  }

  static func unreachable(_ path: String, _ reason: String) -> VMLabError {
    VMLabError(
      code: .guestUnreachable, message: "No VZ runner answers on \(path): \(reason)",
      hint: "The runner has exited or is not started; vm_list reconciles the VM's state.",
      data: ["socket": .string(path)])
  }
}
