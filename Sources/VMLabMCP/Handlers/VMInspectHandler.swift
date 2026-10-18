import VMLabCore

/// `vm_inspect`: the record, the plan it was created from (null for a record older than the plan
/// field), its resolved features, the runtime endpoints, the last 20 events and the latest panic
/// (R-304; null when none), so a model can rediscover a VM after a context reset, and its
/// first-boot report (R-1004): a failed step is a `provision_failed` warning, and a requested
/// provisioning that was never collected (SSH never answered) says so instead of leaving only
/// `ssh_unreachable`. `segments` lists the VM's segment addresses (R-902).
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
    let directory = context.store.directory(of: record.id)
    let report = ProvisionReport.load(from: directory)
    if let warning = report?.warning(vmDirectory: directory) {
      warnings.append(warning)
    } else if report == nil, let spec = record.provision, !spec.isEmpty,
      events.contains(where: { $0.message.hasPrefix("ssh_unreachable") })
    {
      warnings.append(
        "provision_unknown: \(record.id) never answered SSH, so its first-boot provisioning was "
          + "not collected; read vm_serial for cloud-init's output")
    }
    let provisionValue: JSONValue =
      if let report { try JSONValue(encoding: report) } else { .null }
    return ToolResult(
      [
        "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
        "record": try JSONValue(encoding: record),
        "plan": try record.plan.map { plan throws(VMLabError) in try JSONValue(encoding: plan) }
          ?? .null,
        "features": .array(record.features.map { .string($0.rawValue) }),
        "endpoints": .object(Self.endpoints(record, store: context.store)),
        "segments": .array(Self.segments(record, context: context)),
        "events": try JSONValue(encoding: events),
        "panic": panicValue,
        "provision": provisionValue,
      ], warnings: warnings)
  }

  /// How the host reaches the requested guest ports (R-905). QEMU maps each to a loopback port
  /// (`host`, R-308); VZ guests have no port mapping but their NAT address answers from the host,
  /// so `host` is null and `hostReachable` is `<ip>:<guest port>`. Every row has `hostReachable`,
  /// the address to connect to. Nil when the VM forwards nothing or has no address yet.
  static func forwards(_ record: VMRecord) -> [JSONValue]? {
    guard let runtime = record.runtime else { return nil }
    if record.profile.isVZ {
      guard let ip = runtime.ip, !record.network.forwards.isEmpty else { return nil }
      return record.network.forwards.map { forward in
        .object([
          "guest": .number(Double(forward.guest)), "host": .null,
          "hostReachable": .string("\(ip):\(forward.guest)"),
        ])
      }
    }
    guard let forwards = runtime.forwards, !forwards.isEmpty else { return nil }
    return forwards.map { forward in
      .object([
        "guest": .number(Double(forward.guest)),
        "host": forward.host.map { .string("127.0.0.1:\($0)") } ?? .null,
        "hostReachable": forward.host.map { .string("127.0.0.1:\($0)") } ?? .null,
      ])
    }
  }

  /// The VM's place on its segment: name, subnet, address, MAC and the names it answers to.
  static func segments(_ record: VMRecord, context: ToolContext) -> [JSONValue] {
    guard let segment = record.segment else { return [] }
    var object: [String: JSONValue] = [
      "segment": .string(segment.segment), "ip": .string(segment.address),
      "prefixLength": .number(Double(segment.prefixLength)), "mac": .string(segment.mac),
      "names": .array([.string(record.name), .string("\(record.name).\(segment.segment)")]),
    ]
    if let subnet = try? context.manager.segments.load(segment.segment).subnet {
      object["subnet"] = .string(subnet)
    }
    return [.object(object)]
  }

  /// The runtime endpoints; `display` is the profile's endpoint (R-503), absent when it has none.
  static func endpoints(_ record: VMRecord, store: Store) -> [String: JSONValue] {
    guard let runtime = record.runtime else { return [:] }
    var endpoints: [String: JSONValue] = [:]
    if let port = runtime.sshPort { endpoints["ssh"] = .string("127.0.0.1:\(port)") }
    if let ip = runtime.ip { endpoints["ip"] = .string(ip) }
    if let forwards = Self.forwards(record), !forwards.isEmpty {
      endpoints["forwards"] = .array(forwards)
    }
    if let serial = runtime.serialSocket { endpoints["serial"] = .string(serial) }
    if let display = DisplayEndpoint.forVM(record, vmDirectory: store.directory(of: record.id)) {
      endpoints["display"] = display.json
    }
    if let gdb = runtime.gdbEndpoint { endpoints["gdb"] = .string(gdb) }
    if let share = SharedDirSpec.of(record) {
      endpoints["share"] = .object([
        "host": .string(share.hostDirectory(vmDirectory: store.directory(of: record.id)).path),
        "guest": .string(share.guestPath),
      ])
    }
    return endpoints
  }
}
