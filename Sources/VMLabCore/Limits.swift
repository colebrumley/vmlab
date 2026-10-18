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

  /// The largest sizes a request may ask for (Appendix G); `Requirements` refuses more.
  public static let maxCPUs = 256
  public static let maxMemoryGB = 4096
  public static let maxDiskGB = 65536

  /// `resources` with every missing field taken from the defaults for `os`, each kept within
  /// 1 and its cap (a record written by hand or before the caps cannot reach an engine larger).
  public static func resolve(_ resources: ResourceSpec, for os: GuestSpec.OS) -> ResourceSpec {
    let defaults = defaultResources(for: os)
    func clamp(_ value: Int?, _ cap: Int) -> Int? { value.map { min(max($0, 1), cap) } }
    return ResourceSpec(
      cpus: clamp(resources.cpus ?? defaults.cpus, maxCPUs),
      memoryGB: clamp(resources.memoryGB ?? defaults.memoryGB, maxMemoryGB),
      diskGB: clamp(resources.diskGB ?? defaults.diskGB, maxDiskGB))
  }

  /// `count` units of `unit` bytes (`1 << 30` for GiB, `1_000_000_000` for decimal GB), or
  /// `invalid_request` on `field` when it is not positive or does not fit in 64 bits.
  public static func bytes(_ count: Int, unit: UInt64, field: String) throws(VMLabError) -> UInt64 {
    guard count > 0, let value = UInt64(exactly: count) else {
      throw .invalidRequest(
        field: field, reason: "must be positive, got \(count)",
        hint: "Give a positive number or leave the field out for the default.")
    }
    let (bytes, overflow) = value.multipliedReportingOverflow(by: unit)
    guard !overflow else {
      throw .invalidRequest(
        field: field, reason: "\(count) is too large",
        hint: "Use at most \(maxDiskGB) GB of disk and \(maxMemoryGB) GB of memory.")
    }
    return bytes
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

  /// `limit_memory` when the host is under memory pressure (`warn` or `critical`), or when the
  /// memory the kernel can hand out now, less `pendingGB` of starts still in flight, is below
  /// `requestedGB` plus `reserveGB`. `hostGuests` is the number of guests running host-wide.
  public func checkHostMemory(
    requestedGB: Int, pendingGB: Int = 0, snapshot: HostMemorySnapshot, hostGuests: Int
  ) throws(VMLabError) {
    let availableGB = snapshot.availableGB - Double(pendingGB)
    let data: [String: JSONValue] = [
      "pressureLevel": .string(snapshot.pressure.name),
      "availableGB": .number((availableGB * 10).rounded() / 10),
      "requestedGB": .number(Double(requestedGB)), "reserveGB": .number(reserveGB),
      "hostGuests": .number(Double(hostGuests)),
    ]
    if snapshot.pressure.isElevated {
      throw VMLabError(
        code: .limitMemory,
        message:
          "The host is under \(snapshot.pressure.name) memory pressure; starting a "
          + "\(requestedGB) GB guest now would push it into swap",
        hint:
          "Stop or destroy guests you no longer need (vm_list; \(hostGuests) guests run on "
          + "this host, counting other vmlab servers'), then retry.",
        data: data)
    }
    guard Double(requestedGB) + reserveGB > availableGB else { return }
    throw VMLabError(
      code: .limitMemory,
      message:
        "A \(requestedGB) GB guest does not fit in the host's available memory: "
        + "\(Self.format((availableGB * 10).rounded() / 10)) GB is available and "
        + "\(Self.format(reserveGB)) GB stays free for the host",
      hint:
        "Ask for less memory (resources.memoryGB) or stop a running guest (\(hostGuests) run on "
        + "this host, counting other vmlab servers'), then retry.",
      data: data)
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
    /// The engine process, once it runs: matches the guest to a host process (`HostMemory`).
    public var pid: Int32?
    /// `<home>/vms/<id>`, when known: matches the guest to a host process before its pid is
    /// recorded.
    public var directory: String?

    public init(
      id: String? = nil, profile: Profile, os: GuestSpec.OS, memoryGB: Int, pid: Int32? = nil,
      directory: String? = nil
    ) {
      self.id = id
      self.profile = profile
      self.os = os
      self.memoryGB = memoryGB
      self.pid = pid
      self.directory = directory
    }
  }

  public var guests: [Guest]

  public init(guests: [Guest] = []) {
    self.guests = guests
  }

  public static let empty = Inventory()

  /// The live (running or paused) records, each with its memory or the Appendix G default.
  public init(records: [VMRecord]) {
    guests = records.filter(\.state.isLive).map(Guest.init(record:))
  }

  public var macOSGuests: Int { guests.count(where: { $0.os == .macos }) }
  public var memoryGB: Int { guests.reduce(0) { $0 + $1.memoryGB } }

  /// This inventory with one more guest, as after a start.
  public func adding(_ guest: Guest) -> Inventory {
    Inventory(guests: guests + [guest])
  }
}

extension Store {
  /// The live guests of this store as an `Inventory`, each with its VM directory; unreadable
  /// records are skipped.
  public func inventory() -> Inventory {
    Inventory(
      guests: ((try? list().records) ?? []).filter(\.state.isLive).map { startingGuest($0) })
  }

  /// The guest a start of `record` adds, with its VM directory so the gate can tell it from the
  /// host process it is about to become.
  public func startingGuest(_ record: VMRecord) -> Inventory.Guest {
    var guest = Inventory.Guest(record: record)
    guest.directory = directory(of: record.id).path
    return guest
  }
}
