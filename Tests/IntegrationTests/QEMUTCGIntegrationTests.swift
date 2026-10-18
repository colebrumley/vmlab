import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite struct QEMUTCGIntegrationTests {
  /// R-310 Verify (integration, slow): `debian-13-amd64` under qemu-tcg (`qemu-system-x86_64`,
  /// q35, edk2 x86 firmware) reaches `login:` on serial within 10 minutes.
  @Test(.enabled(if: integrationEnabled), .tags(.slow), .timeLimit(.minutes(12)))
  func debianAmd64BootsToLoginUnderTCG() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .netNAT], memoryGB: 2, profile: .qemuTCG,
      guest: GuestSpec(os: .linux, arch: .x86_64), image: "debian-13-amd64", cpus: 4)
    do {
      let log = try String(contentsOf: guest.machine.layout.log, encoding: .utf8)
      #expect(log.contains("qemu-system-x86_64") && log.contains("-machine q35 -accel tcg"))
      #expect(log.contains("edk2-x86_64-code.fd"))
      let started = ContinuousClock.now
      _ = try await guest.machine.serial.wait(for: "login:", since: 0, timeout: .seconds(600))
      print("debian-13-amd64 under TCG reached login: in \(ContinuousClock.now - started)")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
