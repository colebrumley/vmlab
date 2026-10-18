import VMLabCore

/// `vm_list`: one row per VM in the store, optionally only one state or one fleet.
struct VMListHandler: ToolHandler {
  var spec: ToolSpec { .vmList }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    var state: VMState?
    if let name = try arguments.string("state") {
      guard let parsed = VMState(rawValue: name) else {
        throw VMLabError.invalidRequest(
          field: "state", reason: "\(name) is not a VM state",
          hint: "Use one of: \(VMState.allCases.map(\.rawValue).joined(separator: ", ")).")
      }
      state = parsed
    }
    // Records carry no fleet until Phase 9; a fleet filter matches nothing before then.
    let fleet = try arguments.string("fleet")
    let (records, unreadable) = try context.store.list()
    let rows = records.filter { record in
      (state == nil || record.state == state) && fleet == nil
    }.map(Self.row)
    let warnings = unreadable.keys.sorted().map { id in
      "\(id): vm.json does not load (\(unreadable[id]?.message ?? "unreadable"))"
    }
    return ToolResult(["vms": .array(rows)], warnings: warnings)
  }

  static func row(_ record: VMRecord) -> JSONValue {
    var row: [String: JSONValue] = [
      "id": .string(record.id),
      "name": .string(record.name),
      "profile": .string(record.profile.rawValue),
      "state": .string(record.state.rawValue),
      "guest": .object([
        "os": .string(record.guest.os.rawValue), "arch": .string(record.guest.arch.rawValue),
      ]),
    ]
    if let ip = record.runtime?.ip { row["ip"] = .string(ip) }
    if let port = record.runtime?.sshPort { row["sshPort"] = .number(Double(port)) }
    if let reason = record.brokenReason { row["brokenReason"] = .string(reason) }
    return .object(row)
  }
}
