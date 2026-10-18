import Foundation

/// One member of a fleet as `fleets/<name>.json` records it: its VM, or why it has none.
public struct FleetMember: Codable, Sendable, Hashable {
  public var name: String
  /// The VM's id; nil when its create failed.
  public var vm: String?
  /// What went wrong for this member at create (the VM may still exist, e.g. `ssh_unreachable`).
  public var error: VMLabError?
  /// Warnings of its start (`ssh_unreachable`, `hosts_not_updated`).
  public var warnings: [String]

  public init(name: String, vm: String? = nil, error: VMLabError? = nil, warnings: [String] = []) {
    self.name = name
    self.vm = vm
    self.error = error
    self.warnings = warnings
  }
}

/// `VMLAB_HOME/fleets/<name>.json` (R-903): a group of identical VMs made from one plan, joined to
/// one segment.
public struct FleetRecord: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var name: String
  public var createdAt: Date
  public var plan: Plan
  public var image: String
  public var segment: String
  /// The segment was made for this fleet (`segment: auto`) and goes with it.
  public var autoSegment: Bool
  public var members: [FleetMember]

  public init(
    name: String, createdAt: Date, plan: Plan, image: String, segment: String,
    autoSegment: Bool, members: [FleetMember]
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.name = name
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    self.plan = plan
    self.image = image
    self.segment = segment
    self.autoSegment = autoSegment
    self.members = members
  }
}

/// The fleet records under `VMLAB_HOME/fleets/`.
public struct FleetStore: Sendable {
  public let home: URL

  public init(home: URL) { self.home = home }

  public var directory: URL { home.appending(path: "fleets") }
  public func url(of name: String) -> URL { directory.appending(path: "\(name).json") }

  public func list() -> [FleetRecord] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted().compactMap {
      try? load(String($0.dropLast(5)))
    }
  }

  public func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: url(of: name).path)
  }

  public func load(_ name: String) throws(VMLabError) -> FleetRecord {
    try FleetPlanning.checkName(name)
    guard let data = try? Data(contentsOf: url(of: name)) else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "no fleet named \(name)",
        hint: "fleet list shows the fleets; create makes one.")
    }
    do { return try Store.decoder.decode(FleetRecord.self, from: data) } catch {
      throw Store.corrupt(url(of: name).path, "\(error)")
    }
  }

  public func save(_ fleet: FleetRecord) throws(VMLabError) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Store.encoder.encode(fleet).write(to: url(of: fleet.name), options: .atomic)
    } catch {
      throw Store.ioError("write \(url(of: fleet.name).path)", error)
    }
  }

  public func remove(_ name: String) {
    try? FileManager.default.removeItem(at: url(of: name))
  }
}

/// The pure parts of `fleet create`: member names and the budget for every member at once.
public enum FleetPlanning {
  /// The most members one fleet may have.
  public static let maxMembers = 64

  /// A fleet name is also its auto segment's name: `[a-z0-9-]`, at most 28 characters (so
  /// `<name>-64` stays a valid VM name and the segment name fits).
  public static func checkName(_ name: String) throws(VMLabError) {
    guard SegmentStore.isValidName(name), name.utf8.count <= 28 else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "\"\(name)\" is not a fleet name",
        hint: "Use lowercase letters, digits and '-', at most 28 characters.")
    }
  }

  /// `<name>-1` to `<name>-<count>`.
  public static func memberNames(_ name: String, count: Int) -> [String] {
    (1...max(1, count)).map { "\(name)-\($0)" }
  }

  /// Refuses a fleet whose members together would break the macOS limit or the memory budget,
  /// with the same codes and data as a single start (`limit_macos_guests`, `limit_memory` with
  /// `requestedGB` the whole fleet's memory).
  public static func checkBudget(
    plan: Plan, count: Int, running: Inventory, host: HostFacts, limits: ResourceLimits
  ) throws(VMLabError) {
    guard count >= 1, count <= maxMembers else {
      throw VMLabError.invalidRequest(
        field: "count", reason: "count must be 1 to \(maxMembers), got \(count)",
        hint: "Ask for between 1 and \(maxMembers) members.")
    }
    let memoryGB =
      ResourceLimits.resolve(plan.resources, for: plan.guest.os).memoryGB ?? 4
    if Capabilities.guestOS(of: plan.profile) == .macos {
      var inventory = running
      for _ in 0..<count {
        try limits.checkMacOSGuests(profile: plan.profile, running: inventory)
        inventory = inventory.adding(
          Inventory.Guest(profile: plan.profile, os: .macos, memoryGB: memoryGB))
      }
    }
    do {
      try limits.checkMemory(requestedGB: memoryGB * count, running: running, host: host)
    } catch {
      throw VMLabError(
        code: error.code,
        message: "A fleet of \(count) × \(memoryGB) GB does not fit: " + error.message,
        hint: "Ask for fewer members or less memory each, or stop running guests.",
        data: error.data.merging(["count": .number(Double(count))]) { $1 })
    }
  }
}
