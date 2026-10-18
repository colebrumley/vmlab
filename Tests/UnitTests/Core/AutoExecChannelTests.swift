import Foundation
import Synchronization
import Testing
import VMLabCore

/// R-403: `via: auto` takes SSH, and the agent only when SSH never reached the guest.
@Suite struct AutoExecChannelTests {
  final class Scripted: ExecChannel {
    let name: String
    let failure: VMLabError?
    let runs = Mutex(0)

    init(_ name: String, failure: VMLabError? = nil) {
      self.name = name
      self.failure = failure
    }

    var count: Int { runs.withLock { $0 } }

    func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
      runs.withLock { $0 += 1 }
      if let failure { throw failure }
      return ExecResult(exitCode: 0, stdout: name, stderr: "")
    }
  }

  static func unreachable(connected: Bool, _ tried: String = "ssh") -> VMLabError {
    VMLabError(
      code: .guestUnreachable, message: "\(tried) failed", hint: "",
      data: [
        "tried": .array([.string(tried)]), ExecFallback.connectedKey: .bool(connected),
      ])
  }

  @Test func nothingOfferedIsNil() {
    #expect(AutoExecChannel(ssh: nil, agent: nil) == nil)
  }

  @Test func sshWhenItAnswers() async throws {
    let agent = Scripted("agent")
    let auto = try #require(AutoExecChannel(ssh: Scripted("ssh"), agent: agent))
    #expect(try await auto.run(ExecRequest(command: "id")).stdout == "ssh")
    #expect(agent.count == 0)
  }

  @Test func agentWhenSSHNeverConnected() async throws {
    let auto = try #require(
      AutoExecChannel(
        ssh: Scripted("ssh", failure: Self.unreachable(connected: false)), agent: Scripted("agent"))
    )
    #expect(try await auto.run(ExecRequest(command: "id")).stdout == "agent")
  }

  @Test func aCommandThatReachedSSHIsNotRunAgain() async throws {
    let agent = Scripted("agent")
    let auto = try #require(
      AutoExecChannel(
        ssh: Scripted("ssh", failure: Self.unreachable(connected: true)), agent: agent))
    let error = await #expect(throws: VMLabError.self) {
      try await auto.run(ExecRequest(command: "id"))
    }
    #expect(error?.code == .guestUnreachable)
    #expect(agent.count == 0)
  }

  @Test func bothUnreachableSaysWhatWasTried() async throws {
    let auto = try #require(
      AutoExecChannel(
        ssh: Scripted("ssh", failure: Self.unreachable(connected: false)),
        agent: Scripted("agent", failure: Self.unreachable(connected: false, "agent"))))
    let error = await #expect(throws: VMLabError.self) {
      try await auto.run(ExecRequest(command: "id"))
    }
    #expect(error?.code == .guestUnreachable)
    #expect(error?.data["tried"] == .array([.string("ssh"), .string("agent")]))
  }

  @Test func onlyOneChannelIsUsedDirectly() async throws {
    let agentOnly = try #require(AutoExecChannel(ssh: nil, agent: Scripted("agent")))
    #expect(try await agentOnly.run(ExecRequest(command: "id")).stdout == "agent")
    let sshOnly = try #require(AutoExecChannel(ssh: Scripted("ssh"), agent: nil))
    #expect(try await sshOnly.run(ExecRequest(command: "id")).stdout == "ssh")
  }
}
