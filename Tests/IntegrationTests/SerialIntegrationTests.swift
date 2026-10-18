import Foundation
import Testing
import VMLabCore

@Suite struct SerialIntegrationTests {
  /// CPU seconds used by this process's reaped children (the `vmlab-match` helpers here).
  static func childCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_CHILDREN, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
  }

  /// R-303 Verify (integration): the Debian boot log contains `login:` within 90 s via `wait`.
  /// The match runs in `vmlab-match` helpers across the whole boot; their CPU stays small.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
  func debianBootReachesLoginPrompt() async throws {
    let guest = try await QEMUGuest.boot(features: [.serial, .netNAT])
    do {
      let cpuBefore = Self.childCPUSeconds()
      // The channel connected before `cont`, so the log starts at the first byte of firmware output.
      let match = try await guest.machine.serial.wait(
        for: "login:", since: 0, timeout: .seconds(90))
      #expect(match.offset > 0)
      // The helper is killed once the wait matched; wait for it to be reaped, then count its CPU.
      try await Task.sleep(for: .milliseconds(500))
      let matcherCPU = Self.childCPUSeconds() - cpuBefore
      print("serial wait: matched at offset \(match.offset); matcher CPU \(matcherCPU) s")
      #expect(matcherCPU < 2)
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
