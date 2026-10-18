import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// A subcommand that mirrors one MCP tool: it builds the tool's JSON arguments from its flags and
/// calls the same handler `tools/call` does. `--json` prints the result object; otherwise
/// `render` prints a short human summary and any warnings go to stderr. Progress of a long call
/// is printed to stderr.
protocol ToolCommand: AsyncParsableCommand {
  static var toolName: String { get }
  var json: Bool { get }
  /// The tool's arguments, as the model would send them.
  func arguments() throws -> JSONValue
  /// The human rendering of a successful result.
  func render(_ result: ToolResult) -> String
}

extension ToolCommand {
  func run() async throws {
    var context = ToolContext.live()
    // A long call's progress messages go to stderr, so stdout stays the result.
    context.progress = ToolProgress { _, _, message in
      if let message { FileHandle.standardError.write(Data("\(message)...\n".utf8)) }
    }
    let result = try await ToolHandlers.call(
      Self.toolName, arguments: try arguments(), context: context)
    if json {
      print(ToolRendering.json(result.value, pretty: true))
    } else {
      let text = render(result)
      if !text.isEmpty { print(text) }
      for warning in result.warnings {
        FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
      }
    }
  }
}

/// Formatting helpers for the human renderings.
enum Human {
  static func gb(_ value: JSONValue?) -> String {
    String(format: "%.1f GB", value?.numberValue ?? 0)
  }

  static func int(_ value: JSONValue?) -> String {
    value?.numberValue.map { String(Int($0)) } ?? "-"
  }

  static func strings(_ value: JSONValue?) -> [String] {
    value?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  static func list(_ value: JSONValue?) -> String {
    let items = strings(value)
    return items.isEmpty ? "none" : items.joined(separator: ", ")
  }

  static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
  }
}

/// Splits `serial,gdb` and repeated `--require` values into feature names.
func splitList(_ values: [String]) -> [String] {
  values.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
}

// MARK: facts

struct FactsCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "facts", abstract: "Show what this Mac can run (the host_facts tool).")
  static let toolName = "host_facts"

  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue { .object([:]) }

  func render(_ result: ToolResult) -> String {
    let v = result.value
    let qemu = v["qemu"]
    let tart = v["tart"]
    let probes = v["probes"]?["probes"]?.objectValue ?? [:]
    var lines = [
      "macOS \(v["osVersion"]?.stringValue ?? "?") on \(v["chip"]?["model"]?.stringValue ?? "?")",
      "memory \(Human.gb(v["memoryGB"])), free \(Human.gb(v["freeMemoryGB"])); "
        + "free disk \(Human.gb(v["freeDiskGB"]))",
      "qemu: "
        + (qemu?["present"]?.boolValue == true
          ? "\(qemu?["version"]?.stringValue ?? "present") "
            + "(\(Human.list(qemu?["accelerators"])))" : "missing"),
      "tart: "
        + (tart?["present"]?.boolValue == true
          ? tart?["version"]?.stringValue ?? "present"
          : "missing"),
      "rosetta: \(v["rosettaInstalled"]?.boolValue == true ? "installed" : "missing"); "
        + "runner signed: \(v["runnerSigned"]?.boolValue == true ? "yes" : "no"); "
        + "nested virtualization: \(v["nestedSupported"]?.boolValue == true ? "yes" : "no")",
      "running guests: \(Human.int(v["runningGuests"])) "
        + "(\(Human.int(v["runningMacOSGuests"])) macOS)",
    ]
    for name in probes.keys.sorted() {
      lines.append("probe \(name): \(probes[name]?["result"]?.stringValue ?? "unknown")")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: doctor

struct DoctorCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor", abstract: "Check the host's prerequisites (the host_doctor tool).")
  static let toolName = "host_doctor"

  @Flag(help: "Also run the slow probes, each booting a throwaway guest.") var probe = false
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue { .object(["probe": .bool(probe)]) }

  func render(_ result: ToolResult) -> String {
    var lines: [String] = []
    for check in result.value["checks"]?.arrayValue ?? [] {
      let name = check["check"]?.stringValue ?? "?"
      let status = check["status"]?.stringValue ?? "unknown"
      var line = Human.pad(name, 20) + status
      if let detail = check["detail"]?.stringValue { line += " (\(detail))" }
      if let fix = check["fix"]?.stringValue { line += "  fix: \(fix)" }
      lines.append(line)
    }
    lines.append(
      "free memory \(Human.gb(result.value["freeMemoryGB"])), "
        + "free disk \(Human.gb(result.value["freeDiskGB"])), "
        + "running guests \(Human.int(result.value["runningGuests"])) "
        + "(\(Human.int(result.value["runningMacOSGuests"])) macOS)")
    let probes = result.value["probes"]?.objectValue ?? [:]
    for name in probes.keys.sorted() {
      let result = probes[name]?["result"]?.stringValue ?? "unknown"
      let date = probes[name]?["probedAt"]?.stringValue.map { " (probed \($0))" } ?? ""
      let note = probes[name]?["note"]?.stringValue.map { " [\($0)]" } ?? ""
      lines.append("probe " + Human.pad(name, 24) + result + date + note)
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: plan

struct PlanCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan",
    abstract: "Say which engine profile would run a VM, without creating it (the vm_plan tool).")
  static let toolName = "vm_plan"

  @Option(help: "Guest operating system: linux or macos.") var guest: String?
  @Option(help: "Guest architecture.") var arch = "arm64"
  @Option(help: "Required features, comma-separated or repeated (docs/FEATURES.md).")
  var require: [String] = []
  @Option(help: "Preferred features, comma-separated or repeated.") var prefer: [String] = []
  @Option(help: "Virtual CPUs.") var cpus: Int?
  @Option(name: .customLong("memory-gb"), help: "Guest memory in GB.") var memoryGB: Int?
  @Option(name: .customLong("disk-gb"), help: "Disk size in GB.") var diskGB: Int?
  @Option(help: "Network mode: nat or none.") var network: String?
  @Option(help: "A private segment to join.") var segment: String?
  @Option(
    name: .customLong("forward"),
    help: "A guest port to reach from the host, as guest or guest:host; repeatable.")
  var forwards: [String] = []
  @Option(help: "Image or template name.") var image: String?
  @Option(help: "The whole requirements object as JSON, instead of the flags above.")
  var requirements: String?
  @Flag(help: "Treat features whose slow probe has not run as available.")
  var allowUnverified = false
  @Flag(help: "Print the result object as JSON.") var json = false

  func validate() throws {
    if requirements == nil, guest == nil {
      throw ValidationError("Give --guest (linux or macos), or --requirements as JSON.")
    }
    if requirements != nil, guest != nil || !require.isEmpty || !prefer.isEmpty {
      throw ValidationError("--requirements replaces --guest, --require and the other flags.")
    }
  }

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = ["requirements": try requirementsValue()]
    if allowUnverified { object["allowUnverified"] = .bool(true) }
    return .object(object)
  }

  func requirementsValue() throws -> JSONValue {
    if let requirements {
      do {
        return try JSONDecoder().decode(JSONValue.self, from: Data(requirements.utf8))
      } catch {
        throw ValidationError("--requirements is not valid JSON: \(error)")
      }
    }
    var r: [String: JSONValue] = [
      "guest": .object(["os": .string(guest ?? ""), "arch": .string(arch)])
    ]
    let required = splitList(require)
    let preferred = splitList(prefer)
    if !required.isEmpty { r["require"] = .array(required.map { .string($0) }) }
    if !preferred.isEmpty { r["prefer"] = .array(preferred.map { .string($0) }) }
    var resources: [String: JSONValue] = [:]
    if let cpus { resources["cpus"] = .number(Double(cpus)) }
    if let memoryGB { resources["memoryGB"] = .number(Double(memoryGB)) }
    if let diskGB { resources["diskGB"] = .number(Double(diskGB)) }
    if !resources.isEmpty { r["resources"] = .object(resources) }
    var net: [String: JSONValue] = [:]
    if let network { net["mode"] = .string(network) }
    if let segment { net["segment"] = .string(segment) }
    if !forwards.isEmpty { net["forwards"] = .array(try forwards.map(Self.forward)) }
    if !net.isEmpty { r["network"] = .object(net) }
    if let image { r["image"] = .string(image) }
    return .object(r)
  }

  static func forward(_ text: String) throws -> JSONValue {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
    switch parts.count {
    case 1 where parts[0] != nil:
      return .object(["guest": .number(Double(parts[0]!))])
    case 2 where parts[0] != nil && parts[1] != nil:
      return .object(["guest": .number(Double(parts[0]!)), "host": .number(Double(parts[1]!))])
    default:
      throw ValidationError("--forward \(text): expected a port or guest:host ports")
    }
  }

  func render(_ result: ToolResult) -> String {
    let v = result.value
    if v["satisfiable"]?.boolValue == true {
      var lines = [
        "profile \(v["profile"]?.stringValue ?? "?"), "
          + "about \(Human.int(v["estimatedStartupSeconds"])) s to start",
        "features: \(Human.list(v["features"]))",
      ]
      let denied = Human.strings(v["preferredDenied"])
      if !denied.isEmpty {
        lines.append("preferred but missing: \(denied.joined(separator: ", "))")
      }
      let unverified = Human.strings(v["unverified"])
      if !unverified.isEmpty { lines.append("unverified: \(unverified.joined(separator: ", "))") }
      lines += Human.strings(v["notes"]).map { "note: \($0)" }
      return lines.joined(separator: "\n")
    }
    var lines = [
      "unsatisfiable[\(v["code"]?.stringValue ?? "unsatisfiable")]: "
        + (v["message"]?.stringValue ?? "")
    ]
    for suggestion in v["suggestions"]?.arrayValue ?? [] {
      lines.append(
        "drop \(Human.list(suggestion["drop"])) to get "
          + (suggestion["profile"]?.stringValue ?? "?"))
    }
    if let hint = v["hint"]?.stringValue, !hint.isEmpty { lines.append("hint: \(hint)") }
    return lines.joined(separator: "\n")
  }
}

// MARK: list

struct ListCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List the VMs vmlab knows (the vm_list tool).")
  static let toolName = "vm_list"

  @Option(help: "Only VMs in this state.") var state: String?
  @Option(help: "Only members of this fleet.") var fleet: String?
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = [:]
    if let state { object["state"] = .string(state) }
    if let fleet { object["fleet"] = .string(fleet) }
    return .object(object)
  }

  func render(_ result: ToolResult) -> String {
    let rows = result.value["vms"]?.arrayValue ?? []
    if rows.isEmpty { return "no VMs" }
    return rows.map { row in
      let guest =
        "\(row["guest"]?["os"]?.stringValue ?? "?")/"
        + (row["guest"]?["arch"]?.stringValue ?? "?")
      var line =
        Human.pad(row["id"]?.stringValue ?? "?", 11) + Human.pad(row["name"]?.stringValue ?? "", 20)
        + Human.pad(row["profile"]?.stringValue ?? "", 14)
        + Human.pad(row["state"]?.stringValue ?? "", 11) + Human.pad(guest, 14)
      if let ip = row["ip"]?.stringValue { line += " ip \(ip)" }
      if let port = row["sshPort"] { line += " ssh :\(Human.int(port))" }
      return line.trimmingCharacters(in: .whitespaces)
    }.joined(separator: "\n")
  }
}

// MARK: inspect

struct InspectCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "inspect", abstract: "Show everything about one VM (the vm_inspect tool).")
  static let toolName = "vm_inspect"

  @Argument(help: "The VM's id or name.") var vm: String
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue { .object(["vm": .string(vm)]) }

  func render(_ result: ToolResult) -> String {
    let v = result.value
    let record = v["record"]
    var lines = [
      "\(v["vm"]?["id"]?.stringValue ?? "?") \(v["vm"]?["name"]?.stringValue ?? "")",
      "profile \(record?["profile"]?.stringValue ?? "?"), "
        + "state \(record?["state"]?.stringValue ?? "?"), "
        + "guest \(record?["guest"]?["os"]?.stringValue ?? "?")/"
        + (record?["guest"]?["arch"]?.stringValue ?? "?"),
      "features: \(Human.list(v["features"]))",
    ]
    let endpoints = v["endpoints"]?.objectValue ?? [:]
    for name in endpoints.keys.sorted() {
      guard let value = endpoints[name] else { continue }
      let text = value.stringValue ?? value["hostSide"]?.stringValue ?? ToolRendering.json(value)
      lines.append("\(name): \(text)")
    }
    for event in v["events"]?.arrayValue ?? [] {
      lines.append(
        "\(event["ts"]?.stringValue ?? "") \(event["kind"]?.stringValue ?? "") "
          + (event["message"]?.stringValue ?? ""))
    }
    if let panic = v["panic"], panic != .null {
      lines.append(
        "latest panic: \(panic["ts"]?.stringValue ?? "") \(panic["message"]?.stringValue ?? "")")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: logs

struct LogsCommand: ToolCommand {
  static let configuration = CommandConfiguration(
    commandName: "logs",
    abstract: "Show a VM's event, serial and provision logs (the vm_logs tool).")
  static let toolName = "vm_logs"

  @Argument(help: "The VM's id or name.") var vm: String
  @Option(help: "events, serial, provision or all.") var source: String?
  @Option(help: "Only the last N lines of each log.") var tail: Int?
  @Flag(help: "Print the result object as JSON.") var json = false

  func arguments() throws -> JSONValue {
    var object: [String: JSONValue] = ["vm": .string(vm)]
    if let source { object["source"] = .string(source) }
    if let tail { object["tail"] = .number(Double(tail)) }
    return .object(object)
  }

  func render(_ result: ToolResult) -> String {
    (result.value["lines"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
  }
}
