import VMLabCore

/// `vm_inspect`: the record, the plan it was created from (null for a record older than the plan
/// field), its resolved features, the runtime endpoints, the last 20 events and the latest panic
/// (R-304; null when none), so a model can rediscover a VM after a context reset. Segments join
/// when Phase 9 records them.
struct VMInspectHandler: ToolHandler {
  static let eventCount = 20

  var spec: ToolSpec { .vmInspect }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let record = try context.store.find(try arguments.string("vm") ?? "")
    var warnings: [String] = []
    let log = EventLog(vmDirectory: context.store.directory(of: record.id))
    var events: [VMEvent] = []
    var panic: VMEvent?
    do {
      let contents = try await log.read()
      events = Array(contents.events.suffix(Self.eventCount))
      panic = contents.events.last(where: EventLog.isPanic)
      if !contents.skippedLines.isEmpty {
        warnings.append(
          "events.jsonl has \(contents.skippedLines.count) malformed line(s), skipped")
      }
    } catch {
      warnings.append("events.jsonl could not be read: \(error)")
    }
    let panicValue: JSONValue = if let panic { try JSONValue(encoding: panic) } else { .null }
    return ToolResult(
      [
        "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
        "record": try JSONValue(encoding: record),
        "plan": try record.plan.map { plan throws(VMLabError) in try JSONValue(encoding: plan) }
          ?? .null,
        "features": .array(record.features.map { .string($0.rawValue) }),
        "endpoints": .object(Self.endpoints(record, store: context.store)),
        "segments": .array([]),
        "events": try JSONValue(encoding: events),
        "panic": panicValue,
      ], warnings: warnings)
  }

  /// The runtime endpoints; `display` is the profile's endpoint (R-503), absent when it has none.
  static func endpoints(_ record: VMRecord, store: Store) -> [String: JSONValue] {
    guard let runtime = record.runtime else { return [:] }
    var endpoints: [String: JSONValue] = [:]
    if let port = runtime.sshPort { endpoints["ssh"] = .string("127.0.0.1:\(port)") }
    if let ip = runtime.ip { endpoints["ip"] = .string(ip) }
    if let forwards = runtime.forwards, !forwards.isEmpty {
      endpoints["forwards"] = .array(
        forwards.map { forward in
          .object([
            "guest": .number(Double(forward.guest)),
            "host": forward.host.map { .string("127.0.0.1:\($0)") } ?? .null,
          ])
        })
    }
    if let serial = runtime.serialSocket { endpoints["serial"] = .string(serial) }
    if let display = DisplayEndpoint.forVM(record, vmDirectory: store.directory(of: record.id)) {
      endpoints["display"] = display.json
    }
    if let gdb = runtime.gdbEndpoint { endpoints["gdb"] = .string(gdb) }
    return endpoints
  }
}
