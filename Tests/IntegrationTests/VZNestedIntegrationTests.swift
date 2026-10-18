import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// R-609 Verify (integration): with `nested_virt` the guest has `/dev/kvm`. Skipped unless this
/// host supports nested virtualization (M3 or newer, macOS 15); the M1 dev host does not.
@Suite(.serialized) struct VZNestedIntegrationTests {
  static let supported =
    VZRunnerIntegrationTests.ready
    && HostProbe(home: URL(filePath: "/tmp"))
      .gather().nestedSupported

  @Test(.enabled(if: supported), .timeLimit(.minutes(5)))
  func nestedGuestHasKVM() async throws {
    let guest = try await VZGuest.boot(features: [.execSSH, .nestedVirt], tag: "n")
    defer { guest.cleanUp() }
    #expect(await guest.ssh("test -c /dev/kvm")?.status == 0)
    try await guest.manager.perform(.kill, on: guest.id)
  }
}
