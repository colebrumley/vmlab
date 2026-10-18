import Foundation
import Synchronization
import VMLabCore

/// The server's side of a `vmlab-vz` runner's control socket. Each call opens a connection, sends
/// one request line, reads one response line and closes, so a client holds no state a restarted
/// server or runner could invalidate. The blocking socket work runs off the cooperative pool.
public struct VZControlClient: Sendable, Hashable {
  public var socketPath: String
  /// Dead-peer detection (R-1101): while a command that may take longer than this runs, a
  /// `status` probe on a second connection every `probeInterval` must be answered within it.
  public var deadPeerWindow: Duration
  public var probeInterval: Duration

  public init(
    socketPath: String, deadPeerWindow: Duration = DeadPeer.window,
    probeInterval: Duration = DeadPeer.probeInterval
  ) {
    self.socketPath = socketPath
    self.deadPeerWindow = deadPeerWindow
    self.probeInterval = probeInterval
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
    let connection = Connection()
    let watchdog = limit > deadPeerWindow && request.command != .status
    let probe = watchdog ? Task { await watch(connection) } : nil
    defer { probe?.cancel() }
    let result: Result<ControlResponse, VMLabError> = await withCheckedContinuation { done in
      DispatchQueue.global().async {
        done.resume(
          returning: Result { () throws(VMLabError) in
            try Self.exchange(request, path: path, timeout: limit, connection: connection)
          })
      }
    }
    if let reason = connection.deadPeerReason {
      throw DeadPeer.error(channel: "control", endpoint: path, reason: reason)
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

  /// Probes the runner with `status` while a long command runs; a probe that is not answered
  /// within `deadPeerWindow` ends the command's connection and records the reason.
  private func watch(_ connection: Connection) async {
    let probe = VZControlClient(
      socketPath: socketPath, deadPeerWindow: deadPeerWindow, probeInterval: probeInterval)
    while !Task.isCancelled {
      do { try await Task.sleep(for: probeInterval) } catch { return }
      do {
        _ = try await probe.send(ControlRequest(.status), timeout: deadPeerWindow)
      } catch  where error.code == .timeout {
        guard !Task.isCancelled else { return }
        connection.abandon(DeadPeer.silence(deadPeerWindow, waitingFor: "a status probe"))
        return
      } catch {
        return  // the runner is gone or refused: the command's own connection reports it
      }
    }
  }

  /// The descriptor of one exchange, so the watchdog can shut it down, and why it did.
  final class Connection: Sendable {
    private struct State {
      var fd: Int32 = -1
      var reason: String?
    }
    private let state = Mutex(State())

    var deadPeerReason: String? { state.withLock { $0.reason } }

    /// Records `fd`; false (and nothing recorded) when the exchange was already abandoned.
    func open(_ fd: Int32) -> Bool {
      state.withLock { state in
        guard state.reason == nil else { return false }
        state.fd = fd
        return true
      }
    }

    /// Closes the descriptor under the lock `abandon` takes, so it is never shut down reused.
    func close() {
      state.withLock { state in
        if state.fd >= 0 { Darwin.close(state.fd) }
        state.fd = -1
      }
    }

    func abandon(_ reason: String) {
      state.withLock { state in
        guard state.reason == nil else { return }
        state.reason = reason
        if state.fd >= 0 { Darwin.shutdown(state.fd, SHUT_RDWR) }
      }
    }
  }

  static func exchange(
    _ request: ControlRequest, path: String, timeout: Duration,
    connection: Connection = Connection()
  ) throws(VMLabError) -> ControlResponse {
    let line = try ControlCodec.line(request)
    let fd: Int32
    do { fd = try UnixStream.connect(path: path) } catch {
      throw unreachable(path, error.description)
    }
    guard connection.open(fd) else {
      Darwin.close(fd)
      throw unreachable(path, "the runner stopped answering")
    }
    defer { connection.close() }
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
