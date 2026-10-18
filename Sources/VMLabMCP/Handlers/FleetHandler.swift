import Foundation
import VMLabCore

/// `fleet` (R-903, R-904): groups of identical VMs on one segment. create plans once, checks the
/// budget for every member at once, creates and starts `<name>-1..n` in parallel under the start
/// gate (each waits for SSH) and records the fleet in `fleets/<name>.json`, listing members that
/// failed with their error; status, list and destroy read and remove it.
struct FleetHandler: ToolHandler {
  var spec: ToolSpec { .fleet }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let fleets = FleetStore(home: context.home)
    switch try arguments.string("action") ?? "" {
    case "create": return try await create(arguments, context: context, fleets: fleets)
    case "status":
      let fleet = try fleets.load(try Self.name(arguments))
      return ToolResult(Self.status(fleet, context: context))
    case "list":
      return ToolResult([
        "fleets": .array(
          fleets.list().map { fleet in
            .object([
              "name": .string(fleet.name), "segment": .string(fleet.segment),
              "profile": .string(fleet.plan.profile.rawValue),
              "members": .array(fleet.members.map { .string($0.name) }),
            ])
          })
      ])
    case "destroy":
      let fleet = try fleets.load(try Self.name(arguments))
      let destroyed = await Self.destroy(fleet, context: context, fleets: fleets)
      return ToolResult([
        "name": .string(fleet.name), "destroyed": .array(destroyed.map(JSONValue.string)),
      ])
    case "exec":
      throw VMLabError.invalidRequest(
        field: "action", reason: "fleet exec is not built yet (R-904)",
        hint: "Run vm_exec on each member for now.")
    case let action:
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(action) is not a fleet action",
        hint: "Use create, list, status, exec or destroy.")
    }
  }

  // MARK: create

  func create(
    _ arguments: ToolArguments, context: ToolContext, fleets: FleetStore
  ) async throws(VMLabError) -> ToolResult {
    let name = try Self.name(arguments)
    try FleetPlanning.checkName(name)
    guard !fleets.exists(name) else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "the fleet \(name) already exists",
        hint: "Choose another name, or destroy that fleet first.")
    }
    guard let count = try arguments.int("count") else {
      throw VMLabError.invalidRequest(
        field: "count", reason: "create needs count", hint: "Add count: how many members.")
    }
    guard let raw = arguments["requirements"] else {
      throw VMLabError.invalidRequest(
        field: "requirements", reason: "create needs requirements",
        hint: "Add requirements, at least { guest: { os, arch } }.")
    }
    var requirements = try Requirements.decode(json: raw.data)
    if let image = try arguments.string("image") { requirements.image = image }
    let segmentArgument = try arguments.string("segment") ?? "auto"
    let autoSegment = segmentArgument == "auto"
    let segmentName = autoSegment ? name : segmentArgument
    guard requirements.network.mode != .disabled else {
      throw VMLabError.invalidRequest(
        field: "requirements.network.mode", reason: "fleet members join a segment",
        hint: "Leave network.mode out or set it to nat.")
    }
    requirements.network.segment = segmentName
    let names = FleetPlanning.memberNames(name, count: count)
    let taken = Set(((try? context.store.list().records) ?? []).map(\.name))
    if let clash = names.first(where: taken.contains) {
      throw VMLabError.invalidRequest(
        field: "name", reason: "a VM named \(clash) already exists",
        hint: "Choose another fleet name, or destroy \(clash).")
    }

    let plan: Plan
    switch ProfileSelector.select(
      requirements, host: context.hostFacts(), running: context.store.inventory(),
      allowUnverified: try arguments.bool("allowUnverified"), limits: context.limits)
    {
    case .success(let selected): plan = selected
    case .failure(let unsatisfiable): throw unsatisfiable.error
    }
    try FleetPlanning.checkBudget(
      plan: plan, count: count, running: context.store.inventory(), host: context.hostFacts(),
      limits: context.limits)
    await context.progress.step("planned \(count) × \(plan.profile.rawValue)")

    let images = context.images
    let image = try VMCreateHandler.image(
      for: requirements, catalogue: images.catalogue, guestOf: { images.guest(of: $0) })
    var warnings: [String] = []
    if try await LongOperation.pullIfMissing(
      image, confirm: try arguments.bool("confirm"), context: context) != nil
    {
      warnings.append("pulled image \(image) first")
    }
    try LongOperation.checkCancellation("fleet create")

    let segments = context.manager.segments
    if autoSegment {
      if let existing = try? segments.load(segmentName), !existing.auto || !existing.members.isEmpty
      {
        throw VMLabError.invalidRequest(
          field: "segment", reason: "a segment named \(segmentName) already exists",
          hint: "Pass segment: \(segmentName) to join it, or choose another fleet name.")
      }
      if (try? segments.load(segmentName)) == nil { try segments.create(segmentName, auto: true) }
    } else {
      _ = try segments.ensure(segmentName)
    }
    var fleet = FleetRecord(
      name: name, createdAt: Date(), plan: plan, image: image, segment: segmentName,
      autoSegment: autoSegment, members: names.map { FleetMember(name: $0) })
    try fleets.save(fleet)

    let sshTimeout = try arguments.int("timeoutSeconds").map { Duration.seconds($0) }
    let draft = VMRecord(
      id: "", profile: plan.profile, guest: plan.guest, features: plan.features,
      resources: plan.resources, image: image, network: requirements.network,
      boot: requirements.boot, extra: requirements.extra, provision: requirements.provision,
      share: requirements.share, fleet: name)
    let members = try await context.progress.during(
      "creating \(count) members of \(name)", every: context.heartbeat
    ) { () throws(VMLabError) -> [FleetMember] in
      await withTaskGroup(of: (Int, FleetMember).self) { group in
        for (index, member) in names.enumerated() {
          group.addTask {
            var record = draft
            record.name = member
            return (
              index,
              await Self.makeMember(record, plan: plan, sshTimeout: sshTimeout, context: context)
            )
          }
        }
        var results = [FleetMember?](repeating: nil, count: names.count)
        for await (index, member) in group { results[index] = member }
        return results.compactMap { $0 }
      }
    }
    fleet.members = members
    if Task.isCancelled {
      await Task { _ = await Self.destroy(fleet, context: context, fleets: fleets) }.value
      throw LongOperation.cancelled("fleet create")
    }
    try fleets.save(fleet)
    for member in members {
      warnings += member.warnings.map { "\(member.name): \($0)" }
    }
    var object = Self.status(fleet, context: context)
    object["plan"] = try JSONValue(encoding: plan)
    return ToolResult(object, warnings: warnings)
  }

  /// Creates and starts one member; never throws: a failure is the member's `error`.
  static func makeMember(
    _ draft: VMRecord, plan: Plan, sshTimeout: Duration?, context: ToolContext
  ) async -> FleetMember {
    var member = FleetMember(name: draft.name)
    do throws(VMLabError) {
      let created = try await context.manager.create(draft, plan: plan)
      member.vm = created.id
      let started = try await LongOperation.start(created, context: context, sshTimeout: sshTimeout)
      member.warnings = started.warnings
      if let unreachable = started.warnings.first(where: { $0.hasPrefix("ssh_unreachable") }) {
        member.error = VMLabError(
          code: .guestUnreachable, message: unreachable,
          hint: "It is running; retry fleet status, or read vm_serial of \(draft.name).",
          data: ["vm": .string(created.id), "tried": .array([.string("ssh")])])
      }
    } catch {
      member.error = error
    }
    return member
  }

  // MARK: status, destroy

  /// `{ name, segment, subnet, members: [ { vm, id, state, ip, natIP?, error? } ] }`.
  static func status(_ fleet: FleetRecord, context: ToolContext) -> [String: JSONValue] {
    let rows: [JSONValue] = fleet.members.map { member in
      var row: [String: JSONValue] = ["vm": .string(member.name)]
      if let id = member.vm, let record = try? context.store.load(id: id) {
        row["id"] = .string(id)
        row["state"] = .string(record.state.rawValue)
        row["ip"] = record.segment.map { .string($0.address) } ?? .null
        if let ip = record.runtime?.ip { row["natIP"] = .string(ip) }
      } else {
        row["state"] = .string(member.vm == nil ? "failed" : "destroyed")
        row["ip"] = .null
      }
      if let error = member.error, let value = try? JSONValue(encoding: error) {
        row["error"] = value
      }
      return .object(row)
    }
    var object: [String: JSONValue] = [
      "name": .string(fleet.name), "segment": .string(fleet.segment), "members": .array(rows),
    ]
    if let segment = try? context.manager.segments.load(fleet.segment) {
      object["subnet"] = .string(segment.subnet)
    }
    return object
  }

  /// Destroys every member VM (and any VM that names the fleet), the auto segment and the record.
  static func destroy(
    _ fleet: FleetRecord, context: ToolContext, fleets: FleetStore
  ) async -> [String] {
    let records = (try? context.store.list().records) ?? []
    let ids = Set(
      fleet.members.compactMap(\.vm) + records.filter { $0.fleet == fleet.name }.map(\.id))
    let manager = context.manager
    let destroyed = await withTaskGroup(of: String?.self) { group in
      for id in ids {
        group.addTask {
          guard let record = try? context.store.load(id: id) else { return nil }
          do throws(VMLabError) {
            _ = try await manager.perform(.destroy, on: id, force: true)
          } catch {
            return nil
          }
          return record.name
        }
      }
      var names: [String] = []
      for await name in group { if let name { names.append(name) } }
      return names.sorted()
    }
    if fleet.autoSegment { try? context.manager.segments.destroy(fleet.segment) }
    fleets.remove(fleet.name)
    return destroyed
  }

  static func name(_ arguments: ToolArguments) throws(VMLabError) -> String {
    guard let name = try arguments.string("name"), !name.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "name is required for this action", hint: "Add the fleet's name.")
    }
    return name
  }
}
