import Foundation

/// `via: auto` (R-403): SSH when the guest answers it, else the guest agent. The command goes to
/// the agent only when SSH never reached the guest (`ExecFallback.sshNeverConnected`), so a
/// command that started over SSH is never run a second time.
public struct AutoExecChannel: ExecChannel {
  public let ssh: (any ExecChannel)?
  public let agent: (any ExecChannel)?

  /// Nil when neither channel is offered.
  public init?(ssh: (any ExecChannel)?, agent: (any ExecChannel)?) {
    guard ssh != nil || agent != nil else { return nil }
    self.ssh = ssh
    self.agent = agent
  }

  public func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
    guard let ssh else { return try await agent!.run(request) }
    guard let agent else { return try await ssh.run(request) }
    do {
      return try await ssh.run(request)
    } catch  where ExecFallback.sshNeverConnected(error) {
      let sshError = error
      do {
        return try await agent.run(request)
      } catch  where error.code == .guestUnreachable {
        throw ExecFallback.bothUnreachable(ssh: sshError, agent: error)
      }
    }
  }
}

/// How the exec channels say that a command never reached the guest.
public enum ExecFallback {
  /// The `data` key a `guest_unreachable` carries with `false` when the transport never
  /// connected, so the command did not start.
  public static let connectedKey = "connected"

  public static func sshNeverConnected(_ error: VMLabError) -> Bool {
    error.code == .guestUnreachable && error.data[connectedKey] == .bool(false)
  }

  static func bothUnreachable(ssh: VMLabError, agent: VMLabError) -> VMLabError {
    var data = agent.data
    data["tried"] = .array([.string("ssh"), .string("agent")])
    data["sshError"] = .string(ssh.message)
    data["agentError"] = .string(agent.message)
    return VMLabError(
      code: .guestUnreachable,
      message: "Neither SSH nor the guest agent answered: \(agent.message)",
      hint: "The guest may still be booting; wait and retry, or read vm_serial to see where it is.",
      data: data)
  }
}

/// The `timeout` refusal of a foreground command (R-401), with its partial output.
public enum ExecTimeout {
  public static func error(
    vm: String, timeout: Duration, output: ExecOutput.Collected, durationMs: Int,
    cancelled: Bool = false
  ) -> VMLabError {
    let seconds = Double(timeout / .milliseconds(1)) / 1000
    var data: [String: JSONValue] = [
      "vm": .string(vm), "timeoutSeconds": .number(seconds),
      "stdout": .string(output.stdout), "stderr": .string(output.stderr),
      "truncated": .bool(output.truncated), "durationMs": .number(Double(durationMs)),
    ]
    if let log = output.logPath { data["logPath"] = .string(log) }
    if cancelled { data["cancelled"] = .bool(true) }
    return VMLabError(
      code: .timeout,
      message: cancelled
        ? "The command was cancelled and killed"
        : "The command did not finish within \(format(seconds)) s and was killed",
      hint: "Raise timeoutSeconds, or run it with background: true and poll vm_job.",
      data: data)
  }

  static func format(_ seconds: Double) -> String {
    seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
  }
}
