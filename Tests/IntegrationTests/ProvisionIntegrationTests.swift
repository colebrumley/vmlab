import Foundation
import Testing
import VMLabCore
import VMLabMCP

@Suite struct ProvisionIntegrationTests {
  /// R-1001 Verify (integration): a Debian guest created with `packages: [jq]` has
  /// `jq --version` working once cloud-init is done.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(6)))
  func packagesAreInstalledOnFirstBoot() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .execSSH, .netNAT],
      provision: ProvisionSpec(packages: ["jq"], runCommands: ["touch /var/tmp/ran-first-boot"]))
    do {
      let vm = try await guest.manager.attach(guest.record.id)
      let result = try await vm.channel(.exec).run(
        ExecRequest(
          command:
            "cloud-init status --wait >/dev/null; jq --version && test -e /var/tmp/ran-first-boot",
          timeout: .seconds(300)))
      #expect(result.exitCode == 0, "\(result)")
      #expect(result.stdout.hasPrefix("jq-"), "\(result)")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-1004 Verify (integration): a deliberately failing runCommands entry shows up in
  /// provision.json, as the start's warning and in vm_inspect, with the steps before it recorded
  /// and the ones after it skipped.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(6)))
  func failingRunCommandIsReported() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .execSSH, .netNAT],
      provision: ProvisionSpec(runCommands: ["echo first-step", "exit 7", "echo never"]))
    do {
      #expect(
        guest.startWarnings.contains { $0.contains("step runCommands[1] `exit 7` exited 7") },
        "\(guest.startWarnings)")
      let dir = guest.manager.store.directory(of: guest.record.id)
      let report = try #require(ProvisionReport.load(from: dir))
      #expect(
        report.steps.map(\.name) == [
          "cloud-init", "runCommands[0]", "runCommands[1]", "runCommands[2]",
        ])
      #expect(report.steps.dropFirst().map(\.status) == [.succeeded, .failed, .skipped])
      #expect(report.steps[2].exitCode == 7)
      #expect(report.steps[1].durationMs != nil)
      let log = try String(contentsOf: ProvisionReport.logURL(in: dir), encoding: .utf8)
      #expect(log.contains("first-step"), "\(log)")

      let registry = BackendRegistry()
      registry.register(guest.backend)
      let context = ToolContext(home: guest.home, backends: registry)
      let inspected = try await ToolHandlers.call(
        "vm_inspect", arguments: .object(["vm": .string(guest.record.id)]), context: context)
      #expect(inspected.warnings.contains { $0.hasPrefix("provision_failed: \(guest.record.id)") })
      #expect(!inspected.warnings.contains { $0.hasPrefix("ssh_unreachable") })
      #expect(inspected.value["provision"]?["steps"]?.arrayValue?.count == 4)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-1001: on a macOS guest `runCommands` run over SSH once R-606 has installed the VM's key.
  @Test(.disabled("TODO(R-606): macOS first-boot provisioning is not on main yet"))
  func macOSRunCommandsRunOverSSH() async throws {}
}
