import VMLabCore

/// `vm_inspect`: the record, its resolved features, the runtime endpoints and the last 20
/// events. Segments and panics join when Phases 9 and 3 record them.
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
    do {
      let contents = try await log.read()
      events = Array(contents.events.suffix(Self.eventCount))
      if !contents.skippedLines.isEmpty {
        warnings.append(
          "events.jsonl has \(contents.skippedLines.count) malformed line(s), skipped")
      }
    } catch {
      warnings.append("events.jsonl could not be read: \(error)")
    }
    return ToolResult(
      [
        "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
        "record": try JSONValue(encoding: record),
        "features": .array(record.features.map { .string($0.rawValue) }),
        "endpoints": .object(Self.endpoints(record.runtime)),
        "segments": .array([]),
        "events": try JSONValue(encoding: events),
      ], warnings: warnings)
  }

  static func endpoints(_ runtime: VMRuntime?) -> [String: JSONValue] {
    guard let runtime else { return [:] }
    var endpoints: [String: JSONValue] = [:]
    if let port = runtime.sshPort { endpoints["ssh"] = .string("127.0.0.1:\(port)") }
    if let ip = runtime.ip { endpoints["ip"] = .string(ip) }
    if let serial = runtime.serialSocket { endpoints["serial"] = .string(serial) }
    if let vnc = runtime.vncSocket {
      endpoints["display"] = .object(["kind": .string("vnc"), "hostSide": .string(vnc)])
    }
    if let gdb = runtime.gdbEndpoint { endpoints["gdb"] = .string(gdb) }
    return endpoints
  }
}
