import Foundation
import Testing
import VMLabCore

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

  /// R-1001: on a macOS guest `runCommands` run over SSH once R-606 has installed the VM's key.
  @Test(.disabled("TODO(R-606): macOS first-boot provisioning is not on main yet"))
  func macOSRunCommandsRunOverSSH() async throws {}
}
