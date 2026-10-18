import Foundation
import Testing
import VMLabCore
import VMLabEngines

@Suite struct HVFGDBProbeIntegrationTests {
  /// R-702: the probe boots a throwaway HVF machine and answers yes or no (never unknown on a
  /// host with QEMU and HVF); `runAll` persists the answer and the matrix row follows it.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(2)))
  func probeAnswersAndTheMatrixFollows() async throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "vmlab-test-\(getpid())-hvfgdb")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let facts = HostProbe(home: home).gather()
    try #require(facts.qemu.accelerators.contains("hvf"))

    let registry = SlowProbeRegistry()
    registry.register(HVFGDBProbe())
    let outcomes = await registry.runAll(SlowProbeContext(home: home, facts: facts))
    let outcome = try #require(outcomes.first { $0.probe == .qemuHVFGDB })
    #expect(outcome.status == .ran, "\(outcome.note ?? "")")
    print("qemu_hvf_gdb: \(outcome.result.rawValue)")

    let recorded = HostProbe(home: home).gather()
    #expect(recorded.probe(.qemuHVFGDB) == outcome.result)
    let gdb = Capabilities.capabilities(of: .qemuHVF, host: recorded)[.gdb]
    #expect((gdb == .yes) == (outcome.result == .yes))
  }
}
