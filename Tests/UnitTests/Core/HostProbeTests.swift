import Foundation
import Testing
import VMLabCore

/// Replays recorded command output keyed by tool name and arguments.
struct FixtureRunner: CommandRunning {
  var outputs: [String: String]

  func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
    let key = ([URL(filePath: executable).lastPathComponent] + arguments).joined(separator: " ")
    return outputs[key].map { CommandOutput(status: 0, output: $0) }
  }
}

@Suite struct HostProbeTests {
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")

  static func fixture(_ path: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: path), encoding: .utf8)
  }

  @Test func parsesSwVers() throws {
    #expect(HostProbe.parseSwVers(try Self.fixture("host-probe/sw_vers.txt")) == "26.6.2")
  }

  @Test func parsesSysctl() throws {
    let values = HostProbe.parseSysctl(try Self.fixture("host-probe/sysctl.txt"))
    #expect(values["hw.memsize"] == "34359738368")
    let chip = HostProbe.parseChip(brand: values["machdep.cpu.brand_string"] ?? "")
    #expect(chip == HostFacts.Chip(model: "Apple M1 Max", generation: 1))
    #expect(HostProbe.parseChip(brand: "Apple M4 Pro").generation == 4)
    #expect(HostProbe.parseChip(brand: "Intel(R) Core(TM) i9").generation == nil)
  }

  @Test func parsesQEMU() throws {
    #expect(HostProbe.parseQEMUVersion(try Self.fixture("host-probe/qemu-version.txt")) == "11.1.2")
    #expect(
      HostProbe.parseQEMUAccelerators(try Self.fixture("host-probe/qemu-accel-help.txt")) == [
        "hvf", "tcg",
      ])
  }

  @Test func parsesTart() throws {
    #expect(HostProbe.parseTartVersion(try Self.fixture("host-probe/tart-version.txt")) == "2.28.6")
    #expect(HostProbe.parseTartVersion("") == nil)
  }

  @Test func parsesVMStat() throws {
    let bytes = HostProbe.parseVMStatAvailableBytes(try Self.fixture("host-probe/vm_stat.txt"))
    #expect(bytes == Int64((33953 + 628402 + 1909) * 16384))
    #expect(HostProbe.parseVMStatAvailableBytes("garbage") == nil)
  }

  @Test func nestedNeedsM3AndMacOS15() {
    #expect(
      !HostProbe.nestedSupported(
        chip: .init(model: "Apple M1 Max", generation: 1), osVersion: "26.6.2"))
    #expect(
      HostProbe.nestedSupported(chip: .init(model: "Apple M3", generation: 3), osVersion: "15.0"))
    #expect(
      !HostProbe.nestedSupported(chip: .init(model: "Apple M3", generation: 3), osVersion: "14.6"))
  }

  /// R-609: the runner's own answer (`vmlab-vz capabilities`) wins over the chip inference.
  @Test func runnerAnswersNestedSupport() {
    #expect(HostProbe.parseNestedSupported(#"{"nestedVirtualizationSupported":true}"#) == true)
    #expect(HostProbe.parseNestedSupported(#"{"nestedVirtualizationSupported":false}"#) == false)
    #expect(HostProbe.parseNestedSupported("vmlab-vz: unknown command") == nil)
  }

  @Test func gatherCombinesFixturesAndStoredProbes() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Self.fixtures.appending(path: "host-facts/host-facts.json"),
      to: SlowProbes.url(home: home))
    let runner = FixtureRunner(outputs: [
      "sw_vers": try Self.fixture("host-probe/sw_vers.txt"),
      "sysctl machdep.cpu.brand_string hw.memsize": try Self.fixture("host-probe/sysctl.txt"),
      "vm_stat": try Self.fixture("host-probe/vm_stat.txt"),
      "qemu-system-aarch64 --version": try Self.fixture("host-probe/qemu-version.txt"),
      "qemu-system-aarch64 -accel help": try Self.fixture("host-probe/qemu-accel-help.txt"),
      "codesign -d --entitlements - /build/vmlab-vz": try Self.fixture(
        "codesign/vmlab-vz-signed.txt"),
    ])
    let present: Set<String> = [
      "/opt/homebrew/bin/qemu-system-aarch64", "/build/vmlab-vz", HostProbe.rosettaRuntimePath,
    ]
    let probe = HostProbe(
      home: home, runner: runner, runnerPath: "/build/vmlab-vz", searchPaths: ["/opt/homebrew/bin"],
      fileExists: { present.contains($0) }, isRoot: { false }, runningGuests: { (1, 3) })
    let facts = probe.gather()
    #expect(facts.osVersion == "26.6.2")
    #expect(facts.chip.generation == 1)
    #expect(facts.memoryGB == 32)
    #expect(facts.freeMemoryGB > 10)
    #expect(facts.freeDiskGB > 0)
    #expect(!facts.isRoot)
    #expect(
      facts.qemu
        == .init(
          present: true, version: "11.1.2", path: "/opt/homebrew/bin/qemu-system-aarch64",
          accelerators: ["hvf", "tcg"]))
    #expect(facts.tart == .absent)
    #expect(facts.rosettaInstalled)
    #expect(!facts.nestedSupported)
    #expect(facts.runnerSigned)
    #expect(facts.runningMacOSGuests == 1 && facts.runningGuests == 3)
    #expect(facts.probe(.qemuHVFLiveSnapshot) == .yes)
    #expect(facts.probe(.qemuVmnet) == .unknown)
  }

  @Test func unsignedOrMissingRunnerIsNotSigned() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-test-\(UUID())")
    let runner = FixtureRunner(outputs: [
      "codesign -d --entitlements - /build/vmlab-vz": try Self.fixture("codesign/unsigned.txt")
    ])
    let unsigned = HostProbe(
      home: home, runner: runner, runnerPath: "/build/vmlab-vz", searchPaths: [],
      fileExists: { $0 == "/build/vmlab-vz" }, isRoot: { false })
    #expect(!unsigned.gather().runnerSigned)
    let missing = HostProbe(
      home: home, runner: runner, runnerPath: nil, searchPaths: [], fileExists: { _ in false })
    let facts = missing.gather()
    #expect(!facts.runnerSigned)
    #expect(!facts.qemu.present)
    #expect(facts.unverifiedProbes == SlowProbe.allCases.sorted())
  }
}
