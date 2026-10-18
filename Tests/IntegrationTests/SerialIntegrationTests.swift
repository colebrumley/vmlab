import Foundation
import Testing
import VMLabCore

@Suite struct SerialIntegrationTests {
  /// R-303 Verify (integration): the Debian boot log contains `login:` within 90 s via `wait`.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
  func debianBootReachesLoginPrompt() async throws {
    let guest = try await QEMUGuest.boot(features: [.serial, .netNAT])
    do {
      // The channel connected before `cont`, so the log starts at the first byte of firmware output.
      let match = try await guest.machine.serial.wait(
        for: "login:", since: 0, timeout: .seconds(90))
      #expect(match.offset > 0)
      let head = await guest.machine.serial.read(since: 0, maxBytes: 4096)
      #expect(head.start == 0 && !head.text.isEmpty)
      let log = try String(contentsOf: guest.machine.layout.serialLog, encoding: .utf8)
      #expect(log.contains("login:"))
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
