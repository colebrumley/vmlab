import Foundation
import Testing
import VMLabCore
import VMLabMCP
import VMLabQEMU

@Suite struct AgentExecIntegrationTests {
  /// Runs `request` through the agent until it answers (the agent starts once cloud-init has
  /// installed it, or a little after boot), up to `timeout`.
  static func untilAgentAnswers(
    _ vm: any RunningVM, _ request: ExecRequest, timeout: Duration
  ) async throws -> ExecResult {
    let deadline = ContinuousClock.now + timeout
    let channel = try vm.channel(.execAgent)
    while true {
      let result: Result<ExecResult, VMLabError>
      do { result = .success(try await channel.run(request)) } catch { result = .failure(error) }
      if case .failure(let error) = result, error.code == .guestUnreachable,
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .seconds(2))
        continue
      }
      return try result.get()
    }
  }

  /// R-403 Verify (integration): with `net_none`, `vm_exec "id"` via the agent returns `uid=0`,
  /// and `auto` falls back to the agent because SSH has no network.
  ///
  /// Debian's cloud image does not ship qemu-guest-agent and a guest with no network cannot
  /// install it, so the first boot has NAT (cloud-init installs and enables it); the record is
  /// then switched to `net_none` and the same disk boots again with no NIC at all.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func agentExecWithNoNetwork() async throws {
    let guest = try await QEMUGuest.boot(features: [.serial, .execSSH, .execAgent, .netNAT])
    do {
      var vm = try await guest.manager.attach(guest.record.id)
      let first = try await Self.untilAgentAnswers(
        vm, ExecRequest(command: "id", timeout: .seconds(30)), timeout: .seconds(240))
      #expect(first.stdout.hasPrefix("uid=0(root)"), "\(first)")
      let auto = try await vm.channel(.exec).run(ExecRequest(command: "id -un"))
      #expect(auto.stdout == "debian\n", "auto prefers SSH when it answers: \(auto)")

      _ = try await guest.manager.run(.stop, on: guest.record.id)
      try guest.manager.store.update(id: guest.record.id) { record in
        record.network = NetworkSpec(mode: .disabled)
        record.features = [.serial, .execSSH, .execAgent, .netNone]
      }
      let restarted = try await guest.manager.runAdmitted(.start, on: guest.record.id)
      #expect(restarted.warnings.isEmpty, "\(restarted.warnings)")
      vm = try await guest.manager.attach(guest.record.id)
      let logURL = guest.manager.store.directory(of: guest.record.id).appending(path: "qemu.log")
      let qemuLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
      #expect(
        qemuLog.components(separatedBy: "\n").last { $0.hasPrefix("vmlab: ") }?
          .contains("-nic none") == true)

      let none = try await Self.untilAgentAnswers(
        vm, ExecRequest(command: "id; ls /sys/class/net", timeout: .seconds(30)),
        timeout: .seconds(180))
      #expect(none.stdout == "uid=0(root) gid=0(root) groups=0(root)\nlo\n", "\(none)")

      let registry = BackendRegistry()
      registry.register(guest.backend)
      let context = ToolContext(
        home: guest.home, backends: registry, startGate: IntegrationAdmission.gate)
      for via in ["agent", "auto"] {
        let result = try await ToolHandlers.call(
          "vm_exec",
          arguments: .object([
            "vm": .string(guest.record.id), "command": .string("id"), "via": .string(via),
          ]), context: context
        ).value
        #expect(result["exitCode"] == .number(0))
        #expect(result["stdout"]?.stringValue?.hasPrefix("uid=0(root)") == true, "\(via)")
      }
      let piped = try await vm.channel(.execAgent).run(
        ExecRequest(
          command: "cat; echo \"$X\"; pwd; id -un; exit 4", stdin: Data("in\n".utf8),
          cwd: "/tmp", env: ["X": "it's set"], user: "debian"))
      #expect(piped.exitCode == 4)
      #expect(piped.stdout == "in\nit's set\n/tmp\ndebian\n", "\(piped)")

      let started = ContinuousClock.now
      do {
        _ = try await vm.channel(.execAgent).run(
          ExecRequest(command: "echo started; sleep 300", timeout: .seconds(2)))
        Issue.record("sleep 300 returned without a timeout")
      } catch {
        #expect(error.code == .timeout)
        #expect(error.data["stdout"] == .string("started\n"))
      }
      #expect(ContinuousClock.now - started < .seconds(10))
      let left = try await vm.channel(.execAgent).run(
        ExecRequest(command: "ps -eo args | grep '[s]leep 300' || true"))
      #expect(left.stdout == "", "\(left)")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
