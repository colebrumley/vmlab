/// The Appendix G defaults and the dynamic limits a start must respect. The selector (R-103) reads
/// them to pick a profile; the pre-start gate (R-107) reuses the same checks.
public struct ResourceLimits: Sendable, Hashable {
  /// Memory kept free on the host after every running guest and the new one (Appendix G).
  public var reserveGB: Double
  /// macOS guests that may run at once (Apple's limit).
  public var maxMacOSGuests: Int
  /// Starts that may run at once (R-107's `StartGate`).
  public var parallelStarts: Int

  public init(reserveGB: Double = 4, maxMacOSGuests: Int = 2, parallelStarts: Int = 4) {
    self.reserveGB = reserveGB
    self.maxMacOSGuests = maxMacOSGuests
    self.parallelStarts = parallelStarts
  }

  public static let defaults = ResourceLimits()

  /// Appendix G guest defaults: 2 CPUs, 4 GB, 32 GB disk; macOS 4 CPUs, 8 GB and the image's own
  /// disk size (`diskGB: nil`).
  public static func defaultResources(for os: GuestSpec.OS) -> ResourceSpec {
    switch os {
    case .linux: ResourceSpec(cpus: 2, memoryGB: 4, diskGB: 32)
    case .macos: ResourceSpec(cpus: 4, memoryGB: 8, diskGB: nil)
    }
  }

  /// `resources` with every missing field taken from the defaults for `os`.
  public static func resolve(_ resources: ResourceSpec, for os: GuestSpec.OS) -> ResourceSpec {
    let defaults = defaultResources(for: os)
    return ResourceSpec(
      cpus: resources.cpus ?? defaults.cpus, memoryGB: resources.memoryGB ?? defaults.memoryGB,
      diskGB: resources.diskGB ?? defaults.diskGB)
  }

  /// `limit_macos_guests` when starting a `profile` guest would exceed `maxMacOSGuests`.
  public func checkMacOSGuests(profile: Profile, running: Inventory) throws(VMLabError) {
    guard Capabilities.guestOS(of: profile) == .macos else { return }
    let count = running.macOSGuests
    guard count >= maxMacOSGuests else { return }
    throw VMLabError(
      code: .limitMacOSGuests,
      message: "\(count) macOS guests already run; macOS allows at most \(maxMacOSGuests) at once",
      hint: "Stop a running macOS guest (vm_list shows them) before starting another.",
      data: ["running": .number(Double(count))])
  }

  /// `limit_memory` when the running guests plus `requestedGB` would leave less than `reserveGB`
  /// of the host's physical memory free. `freeGB` is physical memory minus the running guests.
  public func checkMemory(requestedGB: Int, running: Inventory, host: HostFacts) throws(VMLabError)
  {
    let freeGB = host.memoryGB - Double(running.memoryGB)
    guard Double(requestedGB) > freeGB - reserveGB else { return }
    throw VMLabError(
      code: .limitMemory,
      message:
        "A \(requestedGB) GB guest does not fit: \(Self.format(freeGB)) GB of "
        + "\(Self.format(host.memoryGB)) GB is not used by running guests and "
        + "\(Self.format(reserveGB)) GB stays free for the host",
      hint: "Ask for less memory (resources.memoryGB) or stop a running guest.",
      data: [
        "requestedGB": .number(Double(requestedGB)), "freeGB": .number(freeGB),
        "reserveGB": .number(reserveGB),
      ])
  }

  /// Both dynamic limits for a guest of `profile` with `memoryGB`, macOS count first.
  public func check(
    profile: Profile, memoryGB: Int, running: Inventory, host: HostFacts
  ) throws(VMLabError) {
    try checkMacOSGuests(profile: profile, running: running)
    try checkMemory(requestedGB: memoryGB, running: running, host: host)
  }

  private static func format(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
  }
}

/// The guests that hold host memory right now: what the dynamic limits count.
public struct Inventory: Sendable, Hashable {
  public struct Guest: Sendable, Hashable {
    public var id: String?
    public var profile: Profile
    public var os: GuestSpec.OS
    public var memoryGB: Int

    public init(id: String? = nil, profile: Profile, os: GuestSpec.OS, memoryGB: Int) {
      self.id = id
      self.profile = profile
      self.os = os
      self.memoryGB = memoryGB
    }
  }

  public var guests: [Guest]

  public init(guests: [Guest] = []) {
    self.guests = guests
  }

  public static let empty = Inventory()

  /// The live (running or paused) records, each with its memory or the Appendix G default.
  public init(records: [VMRecord]) {
    guests = records.filter(\.state.isLive).map { record in
      Guest(
        id: record.id, profile: record.profile, os: record.guest.os,
        memoryGB: record.resources.memoryGB
          ?? ResourceLimits.defaultResources(for: record.guest.os).memoryGB ?? 0)
    }
  }

  public var macOSGuests: Int { guests.count(where: { $0.os == .macos }) }
  public var memoryGB: Int { guests.reduce(0) { $0 + $1.memoryGB } }

  /// This inventory with one more guest, as after a start.
  public func adding(_ guest: Guest) -> Inventory {
    Inventory(guests: guests + [guest])
  }
}

extension Store {
  /// The live guests of this store as an `Inventory`; unreadable records are skipped.
  public func inventory() -> Inventory {
    Inventory(records: (try? list().records) ?? [])
  }
}
