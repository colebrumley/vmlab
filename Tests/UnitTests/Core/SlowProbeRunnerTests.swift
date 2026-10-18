import Foundation
import Testing
import VMLabCore

/// A slow probe runner that answers without booting anything.
struct FakeProbeRunner: SlowProbeRunner {
  var probe: SlowProbe
  var answer: Result<ProbeResult, VMLabError>

  func run(_ context: SlowProbeContext) async throws(VMLabError) -> ProbeResult {
    try answer.get()
  }
}

@Suite struct SlowProbeRunnerTests {
  static func facts() -> HostFacts {
    HostFacts(
      osVersion: "26.6.2", chip: HostFacts.Chip(model: "Apple M1 Max", generation: 1),
      memoryGB: 64, freeMemoryGB: 40, freeDiskGB: 500, isRoot: false,
      qemu: HostFacts.QEMU(present: true, version: "11.1.2", accelerators: ["hvf", "tcg"]),
      tart: .absent, rosettaInstalled: true, nestedSupported: false, runnerSigned: true)
  }

  static func home() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-test-\(UUID())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  @Test func everyProbeHasAnOwner() {
    #expect(SlowProbe.qemuHVFLiveSnapshot.owner == "R-307")
    #expect(SlowProbe.qemuHVFGDB.owner == "R-702")
    #expect(SlowProbe.qemuVmnet.owner == "R-309")
    #expect(SlowProbe.vzLinuxLiveSnapshot.owner == "R-608")
    #expect(SlowProbe.vzMacOSLiveSnapshot.owner == "R-608")
  }

  @Test func withNothingRegisteredEveryProbeIsNotImplementedAndNothingIsWritten() async throws {
    let home = try Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let outcomes = await SlowProbeRegistry().runAll(
      SlowProbeContext(home: home, facts: Self.facts()))
    #expect(outcomes.map(\.probe) == SlowProbe.allCases.sorted())
    #expect(outcomes.allSatisfy { $0.status == .notImplemented && $0.result == .unknown })
    #expect(
      outcomes.first { $0.probe == .qemuHVFGDB }?.note == "not yet implemented (R-702)")
    #expect(!FileManager.default.fileExists(atPath: SlowProbes.url(home: home).path))
  }

  @Test func answersArePersistedWithTheirDateAndVersions() async throws {
    let home = try Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    // An earlier answer for another probe survives the run.
    var earlier = SlowProbes()
    earlier.record(.qemuVmnet, .yes, osVersion: "26.6.2", qemuVersion: "11.1.2")
    try earlier.save(to: SlowProbes.url(home: home))

    let registry = SlowProbeRegistry()
    registry.register(FakeProbeRunner(probe: .qemuHVFGDB, answer: .success(.no)))
    registry.register(FakeProbeRunner(probe: .vzLinuxLiveSnapshot, answer: .success(.yes)))
    registry.register(FakeProbeRunner(probe: .vzMacOSLiveSnapshot, answer: .success(.unknown)))
    registry.register(
      FakeProbeRunner(
        probe: .qemuHVFLiveSnapshot,
        answer: .failure(VMLabError(code: .timeout, message: "guest did not boot", hint: ""))))
    #expect(registry.probes.count == 4)

    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let outcomes = await registry.runAll(
      SlowProbeContext(home: home, facts: Self.facts()), now: { date })
    let status = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.probe, $0.status) })
    #expect(status[.qemuHVFGDB] == .ran && status[.vzLinuxLiveSnapshot] == .ran)
    #expect(status[.vzMacOSLiveSnapshot] == .skipped)
    #expect(status[.qemuHVFLiveSnapshot] == .failed)
    #expect(status[.qemuVmnet] == .notImplemented)
    #expect(
      outcomes.first { $0.probe == .qemuHVFLiveSnapshot }?.note
        == "timeout: guest did not boot")

    let stored = try SlowProbes.load(from: SlowProbes.url(home: home))
    #expect(
      stored[.qemuHVFGDB]
        == ProbeRecord(result: .no, probedAt: date, osVersion: "26.6.2", qemuVersion: "11.1.2"))
    #expect(
      stored[.vzLinuxLiveSnapshot]
        == ProbeRecord(result: .yes, probedAt: date, osVersion: "26.6.2", qemuVersion: nil))
    #expect(stored.result(.qemuVmnet) == .yes)
    #expect(stored.result(.vzMacOSLiveSnapshot) == .unknown)
    #expect(stored.result(.qemuHVFLiveSnapshot) == .unknown)
  }
}
