import Foundation

/// The answer of a slow probe (Appendix E). `unknown` counts as `no` for selection and is reported
/// as `unverified` in `vm_plan` output.
public enum ProbeResult: String, Codable, Sendable, CaseIterable {
  case unknown, yes, no

  /// Whether selection may rely on the feature this probe gates: only a probed `yes` does.
  public var countsAsYes: Bool { self == .yes }

  /// Whether the probe has never run (or its result was invalidated) on this host.
  public var isUnverified: Bool { self == .unknown }
}

/// The slow probes persisted in `host-facts.json`, each owned by the backlog item that runs it.
public enum SlowProbe: String, CaseIterable, Codable, Sendable, Comparable {
  case qemuHVFLiveSnapshot = "qemu_hvf_live_snapshot"
  case qemuHVFGDB = "qemu_hvf_gdb"
  case qemuVmnet = "qemu_vmnet"
  case vzLinuxLiveSnapshot = "vz_linux_live_snapshot"
  case vzMacOSLiveSnapshot = "vz_macos_live_snapshot"

  /// Whether the result depends on the QEMU version (and so is invalidated when QEMU changes).
  public var dependsOnQEMU: Bool {
    switch self {
    case .qemuHVFLiveSnapshot, .qemuHVFGDB, .qemuVmnet: true
    case .vzLinuxLiveSnapshot, .vzMacOSLiveSnapshot: false
    }
  }

  public static func < (lhs: SlowProbe, rhs: SlowProbe) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One slow probe's persisted answer, with the date and the tool versions it was probed with.
public struct ProbeRecord: Codable, Sendable, Equatable {
  public var result: ProbeResult
  public var probedAt: Date?
  public var osVersion: String?
  public var qemuVersion: String?

  public static let unknown = ProbeRecord(result: .unknown)

  public init(
    result: ProbeResult, probedAt: Date? = nil, osVersion: String? = nil, qemuVersion: String? = nil
  ) {
    self.result = result
    self.probedAt = probedAt
    self.osVersion = osVersion
    self.qemuVersion = qemuVersion
  }
}

/// The contents of `VMLAB_HOME/host-facts.json`: slow probe results that survive server restarts.
/// A probe missing from the file is `unknown`; keys this version does not know are ignored.
public struct SlowProbes: Sendable, Equatable {
  public static let fileName = "host-facts.json"
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var records: [SlowProbe: ProbeRecord]

  public init(
    schemaVersion: Int = SlowProbes.currentSchemaVersion, records: [SlowProbe: ProbeRecord] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.records = records
  }

  public subscript(probe: SlowProbe) -> ProbeRecord {
    get { records[probe] ?? .unknown }
    set { records[probe] = newValue }
  }

  public func result(_ probe: SlowProbe) -> ProbeResult { self[probe].result }

  /// Records a probe's answer with the versions it was probed under.
  public mutating func record(
    _ probe: SlowProbe, _ result: ProbeResult, at date: Date = Date(), osVersion: String,
    qemuVersion: String?
  ) {
    self[probe] = ProbeRecord(
      result: result, probedAt: date, osVersion: osVersion,
      qemuVersion: probe.dependsOnQEMU ? qemuVersion : nil)
  }

  /// These results with every record probed under a different macOS version, or (for QEMU probes)
  /// a different QEMU version, reset to `unknown`.
  public func invalidated(osVersion: String, qemuVersion: String?) -> SlowProbes {
    var copy = self
    for (probe, record) in records where record.result != .unknown {
      let osChanged = record.osVersion != osVersion
      let qemuChanged = probe.dependsOnQEMU && record.qemuVersion != qemuVersion
      if osChanged || qemuChanged { copy.records[probe] = .unknown }
    }
    return copy
  }

  public static func url(home: URL) -> URL { home.appending(path: fileName) }

  /// Reads `host-facts.json`; a missing file means every probe is `unknown`.
  public static func load(from url: URL) throws -> SlowProbes {
    guard FileManager.default.fileExists(atPath: url.path) else { return SlowProbes() }
    return try decoder.decode(SlowProbes.self, from: Data(contentsOf: url))
  }

  /// Writes `host-facts.json` atomically (temporary file, then rename).
  public func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded().write(to: url, options: .atomic)
  }

  public func encoded() throws -> Data {
    var data = try Self.encoder.encode(self)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

extension SlowProbes: Codable {
  private enum CodingKeys: String, CodingKey { case schemaVersion, probes }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let raw = try container.decodeIfPresent([String: ProbeRecord].self, forKey: .probes) ?? [:]
    records = Dictionary(
      uniqueKeysWithValues: raw.compactMap { key, value in
        SlowProbe(rawValue: key).map { ($0, value) }
      })
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    let raw = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
    try container.encode(raw, forKey: .probes)
  }
}

/// What vmlab knows about the host (Appendix E): fast facts gathered by `HostProbe` at every server
/// start, plus the persisted slow probes.
public struct HostFacts: Codable, Sendable, Equatable {
  public struct Chip: Codable, Sendable, Equatable {
    /// The CPU brand string, e.g. `Apple M1 Max`.
    public var model: String
    /// The Apple Silicon generation (1 for M1), or nil when the brand string does not say.
    public var generation: Int?

    public init(model: String, generation: Int?) {
      self.model = model
      self.generation = generation
    }
  }

  public struct QEMU: Codable, Sendable, Equatable {
    public var present: Bool
    public var version: String?
    public var path: String?
    /// Accelerators the binary supports, as `-accel help` lists them (`hvf`, `tcg`).
    public var accelerators: [String]

    public init(
      present: Bool, version: String? = nil, path: String? = nil, accelerators: [String] = []
    ) {
      self.present = present
      self.version = version
      self.path = path
      self.accelerators = accelerators
    }

    public static let absent = QEMU(present: false)
  }

  public struct Tart: Codable, Sendable, Equatable {
    public var present: Bool
    public var version: String?

    public init(present: Bool, version: String? = nil) {
      self.present = present
      self.version = version
    }

    public static let absent = Tart(present: false)
  }

  public var osVersion: String
  public var chip: Chip
  public var memoryGB: Double
  public var freeMemoryGB: Double
  public var freeDiskGB: Double
  public var isRoot: Bool
  public var qemu: QEMU
  public var tart: Tart
  public var rosettaInstalled: Bool
  public var nestedSupported: Bool
  public var runnerSigned: Bool
  public var runningMacOSGuests: Int
  public var runningGuests: Int
  public var imagesBytes: Int64
  public var probes: SlowProbes

  public init(
    osVersion: String, chip: Chip, memoryGB: Double, freeMemoryGB: Double, freeDiskGB: Double,
    isRoot: Bool, qemu: QEMU, tart: Tart, rosettaInstalled: Bool, nestedSupported: Bool,
    runnerSigned: Bool, runningMacOSGuests: Int = 0, runningGuests: Int = 0, imagesBytes: Int64 = 0,
    probes: SlowProbes = SlowProbes()
  ) {
    self.osVersion = osVersion
    self.chip = chip
    self.memoryGB = memoryGB
    self.freeMemoryGB = freeMemoryGB
    self.freeDiskGB = freeDiskGB
    self.isRoot = isRoot
    self.qemu = qemu
    self.tart = tart
    self.rosettaInstalled = rosettaInstalled
    self.nestedSupported = nestedSupported
    self.runnerSigned = runnerSigned
    self.runningMacOSGuests = runningMacOSGuests
    self.runningGuests = runningGuests
    self.imagesBytes = imagesBytes
    self.probes = probes
  }

  /// The macOS major version (26 for `26.6.2`), or 0 when unparseable.
  public var osMajorVersion: Int { Int(osVersion.split(separator: ".").first ?? "") ?? 0 }

  /// A slow probe's result on this host.
  public func probe(_ probe: SlowProbe) -> ProbeResult { probes.result(probe) }

  /// Slow probes that have not been verified on this host, in name order.
  public var unverifiedProbes: [SlowProbe] {
    SlowProbe.allCases.filter { probe($0).isUnverified }.sorted()
  }
}
