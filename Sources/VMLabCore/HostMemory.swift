import Darwin
import Foundation
import Synchronization

/// The kernel's memory-pressure level (`kern.memorystatus_vm_pressure_level`): 1 normal, 2 warn,
/// 4 critical. A start is refused at `warn` and above.
public struct MemoryPressure: RawRepresentable, Sendable, Hashable {
  public var rawValue: Int

  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let normal = MemoryPressure(rawValue: 1)
  public static let warn = MemoryPressure(rawValue: 2)
  public static let critical = MemoryPressure(rawValue: 4)

  /// `normal`, `warn`, `critical`, or `level <n>` for a value the kernel does not document.
  public var name: String {
    switch rawValue {
    case 1: "normal"
    case 2: "warn"
    case 4: "critical"
    default: "level \(rawValue)"
    }
  }

  /// Whether starting a guest now would push the host further into swap.
  public var isElevated: Bool { rawValue >= Self.warn.rawValue }
}

/// One host process as `libproc` and `KERN_PROCARGS2` report it: the executable's path and its
/// arguments (without `argv[0]`, as `Process.arguments` has them).
public struct HostProcessInfo: Sendable, Hashable {
  public var pid: Int32
  public var executable: String
  public var arguments: [String]

  public init(pid: Int32, executable: String, arguments: [String]) {
    self.pid = pid
    self.executable = executable
    self.arguments = arguments
  }
}

/// A guest engine process running on the host, whichever `VMLAB_HOME` or server started it.
public struct HostGuestProcess: Sendable, Hashable {
  public var pid: Int32
  /// The engine that recognised it (`qemu`, `vz`).
  public var engine: String
  /// The memory the guest was given (its ceiling, not what it has touched yet).
  public var memoryGB: Double
  /// The VM directory (`<home>/vms/<id>`) when the arguments name it.
  public var directory: String?
  public var os: GuestSpec.OS

  public init(
    pid: Int32, engine: String, memoryGB: Double, directory: String? = nil,
    os: GuestSpec.OS = .linux
  ) {
    self.pid = pid
    self.engine = engine
    self.memoryGB = memoryGB
    self.directory = directory
    self.os = os
  }
}

/// How one engine recognises its guest processes. `matchesExecutable` is checked on the path
/// alone, so arguments are read only for candidate processes.
public struct GuestProcessRecognizer: Sendable {
  public var engine: String
  public var matchesExecutable: @Sendable (String) -> Bool
  public var recognize: @Sendable (HostProcessInfo) -> HostGuestProcess?

  public init(
    engine: String, matchesExecutable: @escaping @Sendable (String) -> Bool,
    recognize: @escaping @Sendable (HostProcessInfo) -> HostGuestProcess?
  ) {
    self.engine = engine
    self.matchesExecutable = matchesExecutable
    self.recognize = recognize
  }
}

/// The recognisers the engine modules register (`Engines.registerAll`), so Core counts guests
/// host-wide without naming an engine (constraint C3).
public final class GuestProcessRecognizers: Sendable {
  public static let shared = GuestProcessRecognizers()

  private let entries = Mutex<[String: GuestProcessRecognizer]>([:])

  public init(_ recognizers: [GuestProcessRecognizer] = []) {
    for recognizer in recognizers { register(recognizer) }
  }

  /// Registers `recognizer` for its engine, replacing any earlier one.
  public func register(_ recognizer: GuestProcessRecognizer) {
    entries.withLock { $0[recognizer.engine] = recognizer }
  }

  public var all: [GuestProcessRecognizer] {
    entries.withLock { $0.values.sorted { $0.engine < $1.engine } }
  }

  /// Whether some recogniser wants the arguments of a process running `executable`.
  public func wants(_ executable: String) -> Bool {
    all.contains { $0.matchesExecutable(executable) }
  }

  /// The guest processes among `processes`, each recognised by the first engine that claims it.
  public func guests(in processes: [HostProcessInfo]) -> [HostGuestProcess] {
    let recognizers = all
    return processes.compactMap { process in
      recognizers.lazy.filter { $0.matchesExecutable(process.executable) }
        .compactMap { $0.recognize(process) }.first
    }
  }
}

/// The host's memory as a start sees it: the pressure level, the memory the kernel can hand out
/// without swapping, and every guest engine process on the host.
public struct HostMemorySnapshot: Sendable, Hashable {
  public var pressure: MemoryPressure
  /// Free + inactive + purgeable (+ speculative) pages, in GiB.
  public var availableGB: Double
  public var guests: [HostGuestProcess]

  public init(pressure: MemoryPressure, availableGB: Double, guests: [HostGuestProcess] = []) {
    self.pressure = pressure
    self.availableGB = availableGB
    self.guests = guests
  }
}

/// Reads the host's memory now. `LiveHostMemory` asks the kernel; tests pass `FixedHostMemory`.
public protocol HostMemoryReading: Sendable {
  func snapshot() -> HostMemorySnapshot
}

/// A reader that always answers `value`: for tests and fixtures.
public struct FixedHostMemory: HostMemoryReading {
  public var value: HostMemorySnapshot

  public init(_ value: HostMemorySnapshot) { self.value = value }

  public func snapshot() -> HostMemorySnapshot { value }
}

/// The kernel's answers, without a subprocess: `sysctlbyname` for the pressure level,
/// `host_statistics64` for the pages, and `libproc` for the guest processes.
public struct LiveHostMemory: HostMemoryReading {
  public var recognizers: GuestProcessRecognizers

  public init(recognizers: GuestProcessRecognizers = .shared) {
    self.recognizers = recognizers
  }

  public func snapshot() -> HostMemorySnapshot {
    let processes = HostProcesses.list(where: recognizers.wants)
    return HostMemorySnapshot(
      pressure: Self.pressure(), availableGB: Double(Self.availableBytes()) / 1_073_741_824,
      guests: recognizers.guests(in: processes))
  }

  /// `kern.memorystatus_vm_pressure_level`, or `normal` when it cannot be read.
  public static func pressure() -> MemoryPressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
    else { return .normal }
    return MemoryPressure(rawValue: Int(level))
  }

  /// Free (which includes speculative), inactive and purgeable pages, in bytes; 0 when the
  /// statistics cannot be read (so a start is refused rather than let through blind).
  public static func availableBytes() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    var pageSize: vm_size_t = 0
    guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else {
      return 0
    }
    let pages =
      UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
    return pages * UInt64(pageSize)
  }
}

/// The host's processes through `libproc` (no `ps` subprocess).
public enum HostProcesses {
  /// Every process whose executable path satisfies `wanted`, with its arguments. Processes of
  /// other users, whose arguments cannot be read, are skipped.
  public static func list(where wanted: (String) -> Bool) -> [HostProcessInfo] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
    let filled = pids.withUnsafeMutableBytes {
      proc_listallpids($0.baseAddress, Int32($0.count))
    }
    guard filled > 0 else { return [] }
    var out: [HostProcessInfo] = []
    for pid in pids.prefix(Int(filled)) where pid > 0 {
      guard let path = executablePath(pid), wanted(path), let arguments = arguments(pid)
      else { continue }
      out.append(HostProcessInfo(pid: pid, executable: path, arguments: arguments))
    }
    return out
  }

  static func executablePath(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(
      decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// `KERN_PROCARGS2` of `pid`, parsed.
  static func arguments(_ pid: Int32) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var argMax: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctl(&mib, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(argMax))
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    size = buffer.count
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parseProcArgs(Array(buffer.prefix(size)))
  }

  /// The arguments in a `KERN_PROCARGS2` buffer: `argc`, the executable path, NUL padding, then
  /// `argc` NUL-terminated strings (`argv[0]` first, dropped here) and the environment.
  public static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
    guard bytes.count >= 4 else { return nil }
    let argc = bytes.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    guard argc > 0 else { return [] }
    var index = 4
    while index < bytes.count, bytes[index] != 0 { index += 1 }  // the executable path
    while index < bytes.count, bytes[index] == 0 { index += 1 }  // its padding
    var argv: [String] = []
    while argv.count < argc, index < bytes.count {
      let start = index
      while index < bytes.count, bytes[index] != 0 { index += 1 }
      argv.append(String(decoding: bytes[start..<index], as: UTF8.self))
      index += 1
    }
    return Array(argv.dropFirst())
  }
}

/// The host-memory part of a start's admission (beyond R-107's budget): the reader, and whether
/// the owner switched the pressure and available-memory refusals off. Only the owner can: through
/// `VMLAB_IGNORE_MEMORY_PRESSURE=1` in the server's environment or `"ignoreMemoryPressure": true`
/// in `VMLAB_HOME/config.json`; no tool argument reaches either.
public struct HostMemoryGuard: Sendable {
  public static let ignoreVariable = "VMLAB_IGNORE_MEMORY_PRESSURE"

  public var reader: any HostMemoryReading
  /// Skips the pressure and available-memory refusals. Guests of other homes and servers still
  /// count against the budget.
  public var ignorePressure: Bool

  public init(reader: any HostMemoryReading, ignorePressure: Bool = false) {
    self.reader = reader
    self.ignorePressure = ignorePressure
  }

  /// The kernel reader, with the escape hatch read from `environment` and `home`'s config.
  public static func live(
    home: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    recognizers: GuestProcessRecognizers = .shared
  ) -> HostMemoryGuard {
    HostMemoryGuard(
      reader: LiveHostMemory(recognizers: recognizers),
      ignorePressure: ignoresPressure(home: home, environment: environment))
  }

  /// Whether the owner set the escape hatch: the variable to `1`, `true` or `yes`, or the key.
  public static func ignoresPressure(home: URL, environment: [String: String]) -> Bool {
    if let value = environment[ignoreVariable]?.lowercased(), ["1", "true", "yes"].contains(value) {
      return true
    }
    return VMLabConfig.load(home: home).ignoreMemoryPressure
  }

  /// Every limit for starting `guest`: the macOS count and the memory budget against `budget`
  /// (this home's live guests plus starts in flight) with the guests of other homes and servers
  /// added, then, unless ignored, the pressure level and the available memory less the memory of
  /// `pending` starts.
  public func check(
    _ guest: Inventory.Guest, budget: Inventory, pending: [Inventory.Guest],
    limits: ResourceLimits, host: HostFacts
  ) throws(VMLabError) {
    let snapshot = reader.snapshot()
    let all = budget.addingHostGuests(snapshot.guests, excluding: guest)
    do {
      try limits.check(profile: guest.profile, memoryGB: guest.memoryGB, running: all, host: host)
    } catch {
      var error = error
      error.data["hostGuests"] = .number(Double(all.guests.count))
      throw error
    }
    guard !ignorePressure else { return }
    try limits.checkHostMemory(
      requestedGB: guest.memoryGB, pendingGB: pending.reduce(0) { $0 + $1.memoryGB },
      snapshot: snapshot, hostGuests: all.guests.count)
  }
}

extension Inventory {
  /// This inventory with the host's guest processes that it does not already hold (matched by
  /// pid or VM directory), and never `guest` itself: what the budget counts host-wide.
  public func addingHostGuests(
    _ processes: [HostGuestProcess], excluding guest: Inventory.Guest? = nil
  ) -> Inventory {
    let known = guests + (guest.map { [$0] } ?? [])
    let pids = Set(known.compactMap(\.pid))
    let directories = Set(known.compactMap { $0.directory.map(Self.canonical) })
    let foreign = processes.filter {
      !pids.contains($0.pid)
        && !($0.directory.map { directories.contains(Self.canonical($0)) }
          ?? false)
    }
    return Inventory(
      guests: guests
        + foreign.map {
          Inventory.Guest(
            profile: $0.os == .macos ? .vzMacOS : $0.engine == "vz" ? .vzLinux : .qemuHVF,
            os: $0.os,
            memoryGB: Int($0.memoryGB.rounded(.up)), pid: $0.pid, directory: $0.directory)
        })
  }

  static func canonical(_ path: String) -> String {
    URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }
}
