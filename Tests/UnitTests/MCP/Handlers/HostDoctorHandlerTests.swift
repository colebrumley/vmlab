import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP
@testable import vmlab

/// `host_doctor`'s report and its terminal rendering, from fixture facts.
@Suite struct HostDoctorHandlerTests {
  static let built = HostDoctorHandler.Runner(path: "/opt/vmlab/vmlab-vz", built: true)

  static func checks(_ report: [String: JSONValue]) -> [String: JSONValue] {
    Dictionary(
      uniqueKeysWithValues: (report["checks"]?.arrayValue ?? []).map {
        ($0["check"]?.stringValue ?? "", $0)
      })
  }

  @Test func fixtureReportWithOneMissingToolShowsItsFixLine() {
    // Everything present except Tart.
    var facts = SlowProbeRunnerTests.facts()
    facts.runningGuests = 3
    facts.runningMacOSGuests = 1
    var probes = SlowProbes()
    probes.record(
      .qemuHVFGDB, .yes, at: Date(timeIntervalSince1970: 1_800_000_000), osVersion: "26.6.2",
      qemuVersion: "11.1.2")
    facts.probes = probes
    let report = HostDoctorHandler.report(facts, runner: Self.built)
    let checks = Self.checks(report)
    #expect(checks.values.filter { $0["status"] != .string("ok") }.count == 1)
    #expect(checks["tart"]?["status"] == .string("missing"))
    #expect(checks["tart"]?["fix"] == .string("brew install cirruslabs/cli/tart"))
    #expect(checks["qemu"]?["fix"] == nil)
    #expect(checks["qemu"]?["detail"] == .string("version 11.1.2"))
    #expect(report["runningGuests"] == .number(3) && report["runningMacOSGuests"] == .number(1))

    let text = DoctorCommand().render(ToolResult(report))
    let lines = text.split(separator: "\n").map(String.init)
    let tart = lines.first { $0.hasPrefix("tart ") }
    #expect(tart?.hasSuffix("missing  fix: brew install cirruslabs/cli/tart") == true)
    #expect(lines.filter { $0.contains("fix:") }.count == 1)
    #expect(text.contains("running guests 3 (1 macOS)"))
    #expect(
      lines.contains { $0.hasPrefix("probe qemu_hvf_gdb") && $0.contains("yes (probed 2027-") })
  }

  @Test func eachPrerequisiteNamesItsFix() {
    let facts = HostFacts(
      osVersion: "26.6.2", chip: HostFacts.Chip(model: "Apple M1", generation: 1), memoryGB: 16,
      freeMemoryGB: 8, freeDiskGB: 5, isRoot: true, qemu: .absent, tart: .absent,
      rosettaInstalled: false, nestedSupported: false, runnerSigned: false)
    let checks = Self.checks(
      HostDoctorHandler.report(facts, runner: .init(path: "/x/vmlab-vz", built: false)))
    #expect(checks["qemu"]?["fix"] == .string("brew install qemu"))
    #expect(checks["qemu_hvf"]?["status"] == .string("unknown"))
    #expect(
      checks["rosetta"]?["fix"] == .string("softwareupdate --install-rosetta --agree-to-license"))
    let buildFix = checks["runner_entitlement"]?["fix"]?.stringValue
    #expect(buildFix?.hasPrefix("scripts/build.sh") == true)
    // Built but unsigned: the fix is the signing step.
    let unsigned = Self.checks(HostDoctorHandler.report(facts, runner: Self.built))
    #expect(unsigned["runner_entitlement"]?["fix"] == .string("scripts/sign.sh"))
    let warnings = HostDoctorHandler.warnings(facts, outcomes: [])
    #expect(warnings.contains { $0.contains("root") })
    #expect(warnings.contains { $0.contains("5.0 GB of disk") })
  }

  @Test func probeRunsTheRegisteredProbesAndReportsTheRest() async throws {
    let context = try ToolHandlerTests.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let registry = SlowProbeRegistry()
    registry.register(FakeProbeRunner(probe: .qemuHVFGDB, answer: .success(.yes)))
    let handler = HostDoctorHandler(registry: registry)
    let result = try await handler.call(
      ToolArguments(.object(["probe": .bool(true)]), spec: handler.spec), context: context)
    let probes = result.value["probes"]?.objectValue ?? [:]
    #expect(probes["qemu_hvf_gdb"]?["result"] == .string("yes"))
    #expect(probes["qemu_hvf_gdb"]?["status"] == .string("ran"))
    #expect(probes["qemu_hvf_gdb"]?["probedAt"] != nil)
    #expect(probes["qemu_vmnet"]?["status"] == .string("not_implemented"))
    #expect(probes["qemu_vmnet"]?["note"] == .string("not yet implemented (R-309)"))
    #expect(probes["qemu_vmnet"]?["result"] == .string("unknown"))
    #expect(
      try SlowProbes.load(from: SlowProbes.url(home: context.home)).result(.qemuHVFGDB) == .yes)

    // Without probe: the persisted answer and its date, no run status.
    let plain = try await handler.call(
      ToolArguments(.object([:]), spec: handler.spec), context: context)
    let gdb = plain.value["probes"]?["qemu_hvf_gdb"]
    #expect(gdb?["result"] == .string("yes") && gdb?["status"] == nil)
  }
}
