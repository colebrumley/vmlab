import Foundation
import Testing

@testable import VMLabCore

/// Slow probes are facts about the host, not about one `VMLAB_HOME`: they live in one host-wide
/// file (`~/.vmlab/host-facts.json`, or `VMLAB_HOST_FACTS`), and a home's own file only overrides.
/// Tests pass the host-wide file explicitly; the process-wide default is none until `vmlab` sets
/// it at startup, so no test reads the real file.
@Suite struct HostWideProbesTests {
  static func directory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-hostwide-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func probes(_ entries: [SlowProbe: ProbeResult]) -> SlowProbes {
    var probes = SlowProbes()
    for (probe, result) in entries {
      probes.record(probe, result, osVersion: "26.6.2", qemuVersion: "11.1.2")
    }
    return probes
  }

  @Test func theDefaultHostFileIgnoresVMLabHome() {
    let user = FileManager.default.homeDirectoryForCurrentUser
    #expect(
      SlowProbes.defaultHostFile(environment: ["VMLAB_HOME": "/tmp/elsewhere"])
        == user.appending(path: ".vmlab/host-facts.json"))
    #expect(
      SlowProbes.defaultHostFile(environment: ["VMLAB_HOST_FACTS": "/tmp/facts.json"])
        == URL(filePath: "/tmp/facts.json"))
    #expect(SlowProbes.defaultHostFile(environment: ["VMLAB_HOST_FACTS": ""]) == nil)
    // Library users and tests get no host-wide file unless they set one.
    #expect(SlowProbes.hostFile == nil)
  }

  @Test func aFreshHomeSeesTheHostWideAnswersAndItsOwnOverride() throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = dir.appending(path: "host-facts.json")
    let home = dir.appending(path: "home")
    try Self.probes([.qemuHVFGDB: .yes, .qemuHVFLiveSnapshot: .yes]).save(to: host)

    let fresh = SlowProbes.effective(home: home, hostFile: host)
    #expect(fresh.result(.qemuHVFGDB) == .yes)
    #expect(fresh.result(.qemuHVFLiveSnapshot) == .yes)

    try Self.probes([.qemuHVFLiveSnapshot: .no]).save(to: SlowProbes.url(home: home))
    let overridden = SlowProbes.effective(home: home, hostFile: host)
    #expect(overridden.result(.qemuHVFGDB) == .yes)
    #expect(overridden.result(.qemuHVFLiveSnapshot) == .no)

    // No host-wide file: the home's own, as before.
    #expect(SlowProbes.effective(home: home, hostFile: nil).result(.qemuHVFGDB) == .unknown)
  }

  @Test func probeRunsRecordHostWideAndRefreshAnExistingOverride() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = dir.appending(path: "host-facts.json")
    let fresh = dir.appending(path: "fresh")
    let registry = SlowProbeRegistry()
    registry.register(FakeProbeRunner(probe: .qemuHVFGDB, answer: .success(.yes)))
    _ = await registry.runAll(
      SlowProbeContext(home: fresh, facts: SlowProbeRunnerTests.facts(), hostFile: host))
    #expect(try SlowProbes.load(from: host).result(.qemuHVFGDB) == .yes)
    #expect(!FileManager.default.fileExists(atPath: SlowProbes.url(home: fresh).path))

    let pinned = dir.appending(path: "pinned")
    try Self.probes([.qemuHVFGDB: .no]).save(to: SlowProbes.url(home: pinned))
    _ = await registry.runAll(
      SlowProbeContext(home: pinned, facts: SlowProbeRunnerTests.facts(), hostFile: host))
    #expect(SlowProbes.effective(home: pinned, hostFile: host).result(.qemuHVFGDB) == .yes)
  }

  @Test func gatherReadsTheHostWideFileAndInvalidatesByVersion() throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = dir.appending(path: "host-facts.json")
    var stale = Self.probes([.qemuHVFGDB: .yes])
    stale.record(.vzLinuxLiveSnapshot, .yes, osVersion: "15.0", qemuVersion: nil)
    try stale.save(to: host)
    let probe = HostProbe(
      home: dir.appending(path: "home"), runner: FixtureRunner(outputs: [:]), runnerPath: nil,
      searchPaths: [], fileExists: { _ in false }, isRoot: { false }, hostFacts: host)
    let probes = probe.storedProbes(osVersion: "26.6.2", qemuVersion: "11.1.2")
    #expect(probes.result(.qemuHVFGDB) == .yes)
    #expect(probes.result(.vzLinuxLiveSnapshot) == .unknown)  // probed under another macOS
  }
}
