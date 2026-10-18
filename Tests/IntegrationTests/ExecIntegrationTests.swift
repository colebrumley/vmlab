import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite struct ExecIntegrationTests {
  static let features: [Feature] = [.serial, .execSSH, .netNAT]

  /// R-400 Verify (integration): the start waits for SSH, then `uname -a` over the VM's key
  /// returns the kernel line with exit 0.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(5)))
  func unameOverSSH() async throws {
    let guest = try await QEMUGuest.boot(features: Self.features)
    do {
      #expect(guest.startWarnings.isEmpty, "\(guest.startWarnings)")
      let vm = try await guest.manager.attach(guest.record.id)
      let result = try await vm.channel(.exec).run(ExecRequest(command: "uname -a"))
      #expect(result.exitCode == 0)
      #expect(result.stdout.hasPrefix("Linux "), "\(result)")
      let dir = guest.manager.store.directory(of: guest.record.id)
      let knownHosts = try String(
        contentsOf: dir.appending(path: "known_hosts"), encoding: .utf8)
      #expect(knownHosts.hasPrefix(guest.record.id + " "))
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
