import Foundation
import Testing
import VMLabCore

@Suite struct HostFactsTests {
  static let fixtureURL = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/host-facts/host-facts.json")

  static func facts(probes: SlowProbes) -> HostFacts {
    HostFacts(
      osVersion: "26.6.2", chip: .init(model: "Apple M1 Max", generation: 1), memoryGB: 32,
      freeMemoryGB: 10, freeDiskGB: 200, isRoot: false,
      qemu: .init(
        present: true, version: "11.1.2", path: "/opt/homebrew/bin/qemu-system-aarch64",
        accelerators: ["hvf", "tcg"]),
      tart: .absent, rosettaInstalled: true, nestedSupported: false, runnerSigned: true,
      probes: probes)
  }

  @Test func fixtureLoadsWithEveryProbe() throws {
    let probes = try SlowProbes.load(from: Self.fixtureURL)
    #expect(probes.schemaVersion == 1)
    #expect(probes.result(.qemuHVFLiveSnapshot) == .yes)
    #expect(probes.result(.qemuHVFGDB) == .no)
    #expect(probes.result(.vzLinuxLiveSnapshot) == .yes)
    #expect(probes.result(.vzMacOSLiveSnapshot) == .unknown)
    #expect(probes.result(.qemuVmnet) == .unknown)  // absent from the file
    #expect(
      probes[.qemuHVFLiveSnapshot].probedAt
        == ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z"))
  }

  @Test func fixtureRoundTrips() throws {
    let probes = try SlowProbes.load(from: Self.fixtureURL)
    let again = try SlowProbes.decoder.decode(SlowProbes.self, from: probes.encoded())
    #expect(again == probes)
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = SlowProbes.url(home: dir)
    try probes.save(to: url)
    #expect(try SlowProbes.load(from: url) == probes)
  }

  @Test func hostFactsRoundTrip() throws {
    let facts = Self.facts(probes: try SlowProbes.load(from: Self.fixtureURL))
    let data = try SlowProbes.encoder.encode(facts)
    #expect(try SlowProbes.decoder.decode(HostFacts.self, from: data) == facts)
  }

  @Test func missingFileMeansAllUnknown() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "vmlab-test-\(UUID())/x.json")
    let probes = try SlowProbes.load(from: url)
    #expect(SlowProbe.allCases.allSatisfy { probes.result($0) == .unknown })
  }

  @Test func unknownKeysAreIgnored() throws {
    let json =
      #"{"schemaVersion":1,"probes":{"future_probe":{"result":"yes"},"qemu_vmnet":{"result":"no"}}}"#
    let probes = try SlowProbes.decoder.decode(SlowProbes.self, from: Data(json.utf8))
    #expect(probes.records == [.qemuVmnet: ProbeRecord(result: .no)])
  }

  /// Unknown counts as no for selection and is reported unverified. The matrix-level assertion
  /// (an unknown probe makes the dependent feature unavailable) is in CapabilitiesTests.
  @Test func unknownCountsAsNoAndIsUnverified() throws {
    #expect(!ProbeResult.unknown.countsAsYes)
    #expect(!ProbeResult.no.countsAsYes)
    #expect(ProbeResult.yes.countsAsYes)
    #expect(ProbeResult.unknown.isUnverified)
    #expect(!ProbeResult.no.isUnverified)
    let facts = Self.facts(probes: try SlowProbes.load(from: Self.fixtureURL))
    #expect(facts.unverifiedProbes == [.qemuVmnet, .vzMacOSLiveSnapshot])
    #expect(!facts.probe(.vzMacOSLiveSnapshot).countsAsYes)
    #expect(facts.probe(.qemuHVFLiveSnapshot).countsAsYes)
  }

  @Test func versionChangesInvalidate() throws {
    let probes = try SlowProbes.load(from: Self.fixtureURL)
    #expect(probes.invalidated(osVersion: "26.6.2", qemuVersion: "11.1.2") == probes)
    let newQEMU = probes.invalidated(osVersion: "26.6.2", qemuVersion: "11.2.0")
    #expect(newQEMU.result(.qemuHVFLiveSnapshot) == .unknown)
    #expect(newQEMU.result(.qemuHVFGDB) == .unknown)
    #expect(newQEMU.result(.vzLinuxLiveSnapshot) == .yes)
    let newOS = probes.invalidated(osVersion: "26.7", qemuVersion: "11.1.2")
    #expect(SlowProbe.allCases.allSatisfy { newOS.result($0) == .unknown })
  }

  @Test func recordStoresVersions() {
    var probes = SlowProbes()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    probes.record(.vzLinuxLiveSnapshot, .yes, at: date, osVersion: "26.6.2", qemuVersion: "11.1.2")
    probes.record(.qemuVmnet, .no, at: date, osVersion: "26.6.2", qemuVersion: "11.1.2")
    #expect(
      probes[.vzLinuxLiveSnapshot] == ProbeRecord(result: .yes, probedAt: date, osVersion: "26.6.2")
    )
    #expect(probes[.qemuVmnet].qemuVersion == "11.1.2")
  }
}
