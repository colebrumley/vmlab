import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite struct QEMUBootIntegrationTests {
  /// R-305 Verify (integration): boot the Debian cloud kernel and initrd extracted from the pulled
  /// image (`images extract-kernel debian-13-arm64`) with `console=ttyAMA0 root=/dev/vda1` and
  /// reach `login:` on serial.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
  func extractedDebianKernelBootsToLogin() async throws {
    let images = ImageStore(
      home: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab"))
    let files = try await images.extractKernel("debian-13-arm64")
    #expect(files.version?.contains("arm64") == true)
    #expect(files.initrd != nil && files.config != nil)

    let guest = try await QEMUGuest.boot(
      features: [.serial, .directKernelBoot, .netNAT],
      boot: BootSpec(mode: .kernel, cmdline: "console=ttyAMA0 root=/dev/vda1"))
    do {
      let args = try String(contentsOf: guest.machine.layout.log, encoding: .utf8)
      #expect(
        args.contains("-kernel /tmp/vmlab-test-") && args.contains("debian-13-arm64/kernel/vmlinuz")
      )
      #expect(!args.contains("if=pflash"))
      _ = try await guest.machine.serial.wait(for: "login:", since: 0, timeout: .seconds(90))
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
