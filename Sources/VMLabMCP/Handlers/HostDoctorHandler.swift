import Foundation
import VMLabCore

/// `host_doctor`: each prerequisite as ok, missing or unknown with the command that fixes it, the
/// VZ runner and its entitlement, free memory and disk, the running guest counts, and the slow
/// probes with the date each was recorded. `probe: true` first runs the registered slow probes
/// (`SlowProbeRunners`) and persists their answers; a probe whose item is not built yet is
/// reported as not implemented and stays `unknown`.
struct HostDoctorHandler: ToolHandler {
  /// Below this much free disk a guest image pull or a new disk may not fit.
  static let lowDiskGB = 20.0

  var spec: ToolSpec { .hostDoctor }
  var registry: SlowProbeRegistry = SlowProbeRunners.shared
  var now: @Sendable () -> Date = { Date() }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let probe = try arguments.bool("probe")
    var facts = context.hostFacts()
    var outcomes: [SlowProbeOutcome] = []
    if probe {
      outcomes = await registry.runAll(
        SlowProbeContext(home: context.home, facts: facts), now: now)
      if outcomes.contains(where: { $0.status == .ran }) { facts = context.hostFacts() }
    }
    let runner = Runner(
      path: context.probe.runnerPath,
      built: context.probe.runnerPath.map(context.probe.fileExists) ?? false)
    return ToolResult(
      Self.report(facts, runner: runner, outcomes: outcomes),
      warnings: Self.warnings(facts, outcomes: outcomes))
  }

  /// Where `vmlab-vz` is and whether it exists.
  struct Runner: Sendable {
    var path: String?
    var built: Bool
  }

  static func check(
    _ name: String, _ status: String, detail: String? = nil, fix: String? = nil
  ) -> JSONValue {
    var entry: [String: JSONValue] = ["check": .string(name), "status": .string(status)]
    if let detail { entry["detail"] = .string(detail) }
    if status != "ok", let fix { entry["fix"] = .string(fix) }
    return .object(entry)
  }

  static func checks(_ facts: HostFacts, runner: Runner) -> [JSONValue] {
    let qemu = facts.qemu
    let qemuDetail = [qemu.version.map { "version \($0)" }, qemu.path].compactMap { $0 }
    let hvf: JSONValue =
      qemu.present
      ? check(
        "qemu_hvf", qemu.accelerators.contains("hvf") ? "ok" : "missing",
        detail: "accelerators: "
          + (qemu.accelerators.isEmpty ? "none" : qemu.accelerators.joined(separator: ", ")),
        fix: "brew reinstall qemu (this build lacks the hvf accelerator)")
      : check("qemu_hvf", "unknown", detail: "QEMU is not installed", fix: "brew install qemu")
    let entitlement: JSONValue
    if runner.built {
      entitlement = check(
        "runner_entitlement", facts.runnerSigned ? "ok" : "missing",
        detail: (facts.runnerSigned
          ? "\(CodeSignature.virtualizationEntitlement) granted"
          : "\(CodeSignature.virtualizationEntitlement) not granted")
          + (runner.path.map { " on \($0)" } ?? ""),
        fix: "scripts/sign.sh")
    } else {
      entitlement = check(
        "runner_entitlement", "missing",
        detail: "vmlab-vz is not built" + (runner.path.map { " (looked for \($0))" } ?? ""),
        fix: "scripts/build.sh (builds vmlab-vz and runs scripts/sign.sh)")
    }
    return [
      check(
        "qemu", qemu.present ? "ok" : "missing",
        detail: qemuDetail.isEmpty ? nil : qemuDetail.joined(separator: ", "),
        fix: "brew install qemu"),
      hvf,
      check(
        "tart", facts.tart.present ? "ok" : "missing",
        detail: facts.tart.version.map { "version \($0)" },
        fix: "brew install cirruslabs/cli/tart"),
      check(
        "rosetta", facts.rosettaInstalled ? "ok" : "missing",
        fix: "softwareupdate --install-rosetta --agree-to-license"),
      entitlement,
    ]
  }

  static func report(
    _ facts: HostFacts, runner: Runner, outcomes: [SlowProbeOutcome] = []
  ) -> [String: JSONValue] {
    let ran = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.probe, $0) })
    let probes = SlowProbe.allCases.map { probe -> (String, JSONValue) in
      let record = facts.probes[probe]
      var entry: [String: JSONValue] = [
        "result": .string(record.result.rawValue), "owner": .string(probe.owner),
      ]
      if let date = record.probedAt { entry["probedAt"] = .string(date.formatted(.iso8601)) }
      if let outcome = ran[probe] {
        entry["status"] = .string(outcome.status.rawValue)
        if let note = outcome.note { entry["note"] = .string(note) }
      }
      return (probe.rawValue, .object(entry))
    }
    var runnerEntry: [String: JSONValue] = [
      "built": .bool(runner.built), "entitled": .bool(facts.runnerSigned),
    ]
    if let path = runner.path { runnerEntry["path"] = .string(path) }
    return [
      "checks": .array(checks(facts, runner: runner)),
      "probes": .object(Dictionary(uniqueKeysWithValues: probes)),
      "runner": .object(runnerEntry),
      "freeMemoryGB": .number(facts.freeMemoryGB),
      "freeDiskGB": .number(facts.freeDiskGB),
      "runningGuests": .number(Double(facts.runningGuests)),
      "runningMacOSGuests": .number(Double(facts.runningMacOSGuests)),
    ]
  }

  static func warnings(_ facts: HostFacts, outcomes: [SlowProbeOutcome]) -> [String] {
    var warnings: [String] = []
    if facts.isRoot {
      warnings.append("vmlab is running as root; it never needs to, run it as your user")
    }
    if facts.freeDiskGB < lowDiskGB {
      warnings.append(
        String(
          format: "only %.1f GB of disk is free; a guest image or disk may not fit",
          facts.freeDiskGB))
    }
    let missing = outcomes.filter { $0.status == .notImplemented }.map(\.probe)
    if !missing.isEmpty {
      warnings.append(
        "slow probes not built yet, left as they were: "
          + missing.map { "\($0.rawValue) (\($0.owner))" }.joined(separator: ", "))
    }
    for outcome in outcomes where outcome.status == .failed || outcome.status == .skipped {
      warnings.append(
        "probe \(outcome.probe.rawValue) \(outcome.status.rawValue): \(outcome.note ?? "")")
    }
    return warnings
  }
}
