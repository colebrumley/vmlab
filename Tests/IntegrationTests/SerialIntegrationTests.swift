import Testing
import VMLabCore

@Suite struct SerialIntegrationTests {
  /// R-303 Verify (integration): the Debian boot log contains `login:` within 90 s via `wait`.
  @Test(
    .enabled(if: integrationEnabled),
    .disabled("TODO(R-302): needs the QEMU backend to boot the Debian guest with a serial socket"))
  func debianBootReachesLoginPrompt() async throws {}
}
