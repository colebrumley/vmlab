import Testing
import VMLabRFB

@Suite struct RFBIntegrationTests {
  /// R-500 Verify (integration): connect to the Debian guest's QEMU VNC socket during boot and get
  /// a non-blank image.
  @Test(
    .enabled(if: integrationEnabled),
    .disabled("TODO(R-302): needs the QEMU backend to boot the Debian guest with a VNC socket"))
  func debianBootScreenIsNotBlank() async throws {}
}
