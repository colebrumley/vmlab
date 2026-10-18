import VMLabCore

/// `host_doctor`, minimal until R-203: each prerequisite from the fast facts as ok or missing
/// with its fix, the free memory and disk, the running guest counts and the persisted probes.
struct HostDoctorHandler: ToolHandler {
  var spec: ToolSpec { .hostDoctor }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    var warnings: [String] = []
    if try arguments.bool("probe") {
      warnings.append(
        "no slow probe is built yet (R-307, R-608 and R-702 add them); the persisted results "
          + "are shown")
    }
    let facts = context.hostFacts()
    return ToolResult(Self.report(facts), warnings: warnings)
  }

  static func report(_ facts: HostFacts) -> [String: JSONValue] {
    func check(_ name: String, _ ok: Bool, fix: String) -> JSONValue {
      var entry: [String: JSONValue] = [
        "check": .string(name), "status": .string(ok ? "ok" : "missing"),
      ]
      if !ok { entry["fix"] = .string(fix) }
      return .object(entry)
    }
    let checks: [JSONValue] = [
      check("qemu", facts.qemu.present, fix: "brew install qemu"),
      check("tart", facts.tart.present, fix: "brew install cirruslabs/cli/tart"),
      check(
        "rosetta", facts.rosettaInstalled,
        fix: "softwareupdate --install-rosetta --agree-to-license"
      ),
      check(
        "runner_signed", facts.runnerSigned,
        fix: "scripts/build.sh (signs vmlab-vz with the virtualization entitlement)"),
    ]
    let probes = SlowProbe.allCases.map { probe -> (String, JSONValue) in
      let record = facts.probes[probe]
      var entry: [String: JSONValue] = ["result": .string(record.result.rawValue)]
      if let date = record.probedAt { entry["probedAt"] = .string(date.formatted(.iso8601)) }
      return (probe.rawValue, .object(entry))
    }
    return [
      "checks": .array(checks),
      "probes": .object(Dictionary(uniqueKeysWithValues: probes)),
      "freeMemoryGB": .number(facts.freeMemoryGB),
      "freeDiskGB": .number(facts.freeDiskGB),
      "runningGuests": .number(Double(facts.runningGuests)),
      "runningMacOSGuests": .number(Double(facts.runningMacOSGuests)),
    ]
  }
}
