import Foundation

/// What a request names in `require` and `prefer` (Appendix A).
public enum Feature: String, CaseIterable, Codable, Sendable {
  case execSSH = "exec_ssh"
  case execAgent = "exec_agent"
  case gui
  case guiPreboot = "gui_preboot"
  case guiDesktop = "gui_desktop"
  case guiAccel = "gui_accel"
  case serial
  case gdb
  case introspection
  case memoryDump = "memory_dump"
  case directKernelBoot = "direct_kernel_boot"
  case customFirmware = "custom_firmware"
  case customDevices = "custom_devices"
  case haltAtStart = "halt_at_start"
  case checkpointDisk = "checkpoint_disk"
  case checkpointLive = "checkpoint_live"
  case pause
  case netNAT = "net_nat"
  case netFast = "net_fast"
  case netSegment = "net_segment"
  case netPortForward = "net_port_forward"
  case netNone = "net_none"
  case rosetta
  case nestedVirt = "nested_virt"
  case sharedDir = "shared_dir"
  case cloudInit = "cloud_init"
  case manyGuests = "many_guests"

  /// How the model uses a feature.
  public enum Kind: String, CaseIterable, Codable, Sendable {
    case channel, boot, state, net, compute
  }

  public var kind: Kind {
    switch self {
    case .execSSH, .execAgent, .gui, .guiPreboot, .guiDesktop, .serial, .gdb, .introspection,
      .memoryDump:
      .channel
    case .directKernelBoot, .customFirmware, .customDevices, .haltAtStart, .cloudInit: .boot
    case .checkpointDisk, .checkpointLive, .pause: .state
    case .netNAT, .netFast, .netSegment, .netPortForward, .netNone: .net
    case .guiAccel, .rosetta, .nestedVirt, .sharedDir, .manyGuests: .compute
    }
  }

  public var summary: String {
    switch self {
    case .execSSH: "Run commands and move files over SSH with a per-VM key"
    case .execAgent: "Run commands with no guest network, through a host-side agent channel"
    case .gui: "Screenshots and pointer/keyboard input on the guest display"
    case .guiPreboot: "The display works before any OS is running (firmware, bootloader)"
    case .guiDesktop: "A desktop environment is installed in a Linux guest"
    case .guiAccel: "Paravirtualized graphics; smooth desktop use"
    case .serial: "A serial console captured from the first byte, readable and writable"
    case .gdb: "A GDB stub on the guest CPU: halt, step, breakpoints, registers, memory"
    case .introspection: "Machine state queries: PCI, block, memory map, CPU registers"
    case .memoryDump: "Dump guest physical memory to a file"
    case .directKernelBoot: "Boot a kernel and initrd without a disk-resident bootloader"
    case .customFirmware: "Supply the firmware or bootloader image itself"
    case .customDevices: "Pass arbitrary virtual-device arguments to the engine"
    case .haltAtStart: "The CPU starts halted so the first instruction can be debugged"
    case .checkpointDisk: "Named disk snapshots of a stopped guest"
    case .checkpointLive: "Named snapshots of a running guest including memory"
    case .pause: "Pause and resume without saving to disk"
    case .netNAT: "Outbound internet through host NAT"
    case .netFast: "NAT on the fast vmnet path rather than user-mode networking"
    case .netSegment: "A second NIC on a private host-local segment shared with other guests"
    case .netPortForward: "A guest port reachable from the host"
    case .netNone: "No network device at all"
    case .rosetta: "Run amd64 Linux binaries in an arm64 Linux guest"
    case .nestedVirt: "The guest can run its own hypervisor"
    case .sharedDir: "A host directory mounted in the guest"
    case .cloudInit: "First-boot provisioning for Linux guests"
    case .manyGuests: "More than two instances may run at once"
    }
  }

  /// The catalogue as a Markdown table, in declaration order.
  public static func catalogueMarkdown() -> String {
    var lines = ["| Feature | Kind | Meaning |", "|---|---|---|"]
    for feature in allCases {
      lines.append("| `\(feature.rawValue)` | \(feature.kind.rawValue) | \(feature.summary) |")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// The guest a request asks for. OS and architecture are fields, not features.
public struct GuestSpec: Codable, Sendable, Hashable {
  public enum OS: String, CaseIterable, Codable, Sendable {
    case macos, linux
  }

  public enum Arch: Codable, Sendable, Hashable, RawRepresentable {
    case arm64
    // swift-format-ignore: AlwaysUseLowerCamelCase
    case x86_64
    case riscv64
    case other(String)

    public init(rawValue: String) {
      switch rawValue {
      case "arm64": self = .arm64
      case "x86_64": self = .x86_64
      case "riscv64": self = .riscv64
      default: self = .other(rawValue)
      }
    }

    public var rawValue: String {
      switch self {
      case .arm64: "arm64"
      case .x86_64: "x86_64"
      case .riscv64: "riscv64"
      case .other(let name): name
      }
    }

    public init(from decoder: any Decoder) throws {
      self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }

  public var os: OS
  public var arch: Arch

  public init(os: OS, arch: Arch) {
    self.os = os
    self.arch = arch
  }
}

/// Guest resources; `nil` takes the Appendix G default for the guest.
public struct ResourceSpec: Codable, Sendable, Hashable {
  public var cpus: Int?
  public var memoryGB: Int?
  public var diskGB: Int?

  public init(cpus: Int? = nil, memoryGB: Int? = nil, diskGB: Int? = nil) {
    self.cpus = cpus
    self.memoryGB = memoryGB
    self.diskGB = diskGB
  }
}

/// A guest port made reachable on the host; `host: nil` lets vmlab choose.
public struct PortForward: Codable, Sendable, Hashable {
  public var guest: Int
  public var host: Int?

  public init(guest: Int, host: Int? = nil) {
    self.guest = guest
    self.host = host
  }
}

public struct NetworkSpec: Codable, Sendable, Hashable {
  public enum Mode: String, CaseIterable, Codable, Sendable {
    case nat
    case disabled = "none"
  }

  public var mode: Mode?
  public var segment: String?
  public var forwards: [PortForward]

  public init(mode: Mode? = nil, segment: String? = nil, forwards: [PortForward] = []) {
    self.mode = mode
    self.segment = segment
    self.forwards = forwards
  }

  enum CodingKeys: String, CodingKey { case mode, segment, forwards }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = try c.decodeIfPresent(Mode.self, forKey: .mode)
    segment = try c.decodeIfPresent(String.self, forKey: .segment)
    forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
  }
}

public struct BootSpec: Codable, Sendable, Hashable {
  public enum Mode: String, CaseIterable, Codable, Sendable {
    case disk, kernel, firmware
  }

  public var mode: Mode
  public var kernel: String?
  public var initrd: String?
  public var cmdline: String?
  public var firmware: String?
  public var haltAtStart: Bool

  public init(
    mode: Mode = .disk, kernel: String? = nil, initrd: String? = nil, cmdline: String? = nil,
    firmware: String? = nil, haltAtStart: Bool = false
  ) {
    self.mode = mode
    self.kernel = kernel
    self.initrd = initrd
    self.cmdline = cmdline
    self.firmware = firmware
    self.haltAtStart = haltAtStart
  }

  enum CodingKeys: String, CodingKey { case mode, kernel, initrd, cmdline, firmware, haltAtStart }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .disk
    kernel = try c.decodeIfPresent(String.self, forKey: .kernel)
    initrd = try c.decodeIfPresent(String.self, forKey: .initrd)
    cmdline = try c.decodeIfPresent(String.self, forKey: .cmdline)
    firmware = try c.decodeIfPresent(String.self, forKey: .firmware)
    haltAtStart = try c.decodeIfPresent(Bool.self, forKey: .haltAtStart) ?? false
  }
}

/// The `requirements` input of `vm_plan`, `vm_create` and `fleet create` (Appendix C). Decoding
/// rejects a request that contradicts itself with `invalid_request`.
public struct Requirements: Codable, Sendable, Hashable {
  public var guest: GuestSpec
  public var require: [Feature]
  public var prefer: [Feature]
  public var resources: ResourceSpec
  public var network: NetworkSpec
  public var image: String?
  public var boot: BootSpec?

  /// Builds a request and checks it as decoding would.
  public init(
    guest: GuestSpec, require: [Feature] = [], prefer: [Feature] = [],
    resources: ResourceSpec = ResourceSpec(), network: NetworkSpec = NetworkSpec(),
    image: String? = nil, boot: BootSpec? = nil
  ) throws(VMLabError) {
    self.guest = guest
    self.require = require
    self.prefer = prefer
    self.resources = resources
    self.network = network
    self.image = image
    self.boot = boot
    try validate()
  }

  enum CodingKeys: String, CodingKey {
    case guest, require, prefer, resources, network, image, boot
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guest = try c.decode(GuestSpec.self, forKey: .guest)
    require = try Self.decodeFeatures(c, .require)
    prefer = try Self.decodeFeatures(c, .prefer)
    resources = try c.decodeIfPresent(ResourceSpec.self, forKey: .resources) ?? ResourceSpec()
    network = try c.decodeIfPresent(NetworkSpec.self, forKey: .network) ?? NetworkSpec()
    image = try c.decodeIfPresent(String.self, forKey: .image)
    boot = try c.decodeIfPresent(BootSpec.self, forKey: .boot)
    try validate()
  }

  /// Decodes a JSON request, reporting every failure, malformed or contradictory, as a
  /// `VMLabError` with code `invalid_request`.
  public static func decode(json: Data) throws(VMLabError) -> Requirements {
    do {
      return try JSONDecoder().decode(Requirements.self, from: json)
    } catch let error as VMLabError {
      throw error
    } catch let error as DecodingError {
      throw invalidRequest(from: error)
    } catch {
      throw VMLabError.invalidRequest(
        field: "requirements", reason: "\(error)", hint: "Send requirements as a JSON object.")
    }
  }

  private static func decodeFeatures(
    _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
  ) throws -> [Feature] {
    let names = try c.decodeIfPresent([String].self, forKey: key) ?? []
    return try names.enumerated().map { index, name throws(VMLabError) in
      guard let feature = Feature(rawValue: name) else {
        throw VMLabError.invalidRequest(
          field: "\(key.rawValue)[\(index)]", reason: "unknown feature \"\(name)\"",
          hint: "Use a feature from the catalogue: "
            + Feature.allCases.map(\.rawValue).joined(separator: ", "))
      }
      return feature
    }
  }

  private static func invalidRequest(from error: DecodingError) -> VMLabError {
    func path(_ keys: [any CodingKey], _ last: (any CodingKey)? = nil) -> String {
      let all = keys + (last.map { [$0] } ?? [])
      let joined = all.map { key in
        key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
      }.joined()
      let trimmed = joined.hasPrefix(".") ? String(joined.dropFirst()) : joined
      return trimmed.isEmpty ? "requirements" : trimmed
    }
    switch error {
    case .keyNotFound(let key, let context):
      return .invalidRequest(
        field: path(context.codingPath, key), reason: "missing field",
        hint: "Add the field \"\(key.stringValue)\".")
    case .typeMismatch(_, let context), .valueNotFound(_, let context):
      return .invalidRequest(
        field: path(context.codingPath), reason: context.debugDescription,
        hint: "Fix the type of this field (Appendix C).")
    case .dataCorrupted(let context):
      return .invalidRequest(
        field: path(context.codingPath), reason: context.debugDescription,
        hint: "Use one of the values Appendix C allows for this field.")
    @unknown default:
      return .invalidRequest(
        field: "requirements", reason: "\(error)", hint: "Check the request against Appendix C.")
    }
  }

  /// Every feature the request names or implies, with the field that names it. `network.mode`,
  /// `network.forwards`, `network.segment` and `boot` imply the matching features.
  private var namedFeatures: [(feature: Feature, field: String)] {
    var named = require.enumerated().map { ($0.element, "require[\($0.offset)]") }
    named += prefer.enumerated().map { ($0.element, "prefer[\($0.offset)]") }
    return named + impliedFeatures
  }

  /// The features `network` and `boot` imply, with the field that implies each. The selector
  /// requires them as if `require` named them.
  var impliedFeatures: [(feature: Feature, field: String)] {
    var named: [(feature: Feature, field: String)] = []
    switch network.mode {
    case .nat: named.append((.netNAT, "network.mode"))
    case .disabled: named.append((.netNone, "network.mode"))
    case nil: break
    }
    if !network.forwards.isEmpty { named.append((.netPortForward, "network.forwards")) }
    if network.segment != nil { named.append((.netSegment, "network.segment")) }
    if let boot {
      switch boot.mode {
      case .kernel: named.append((.directKernelBoot, "boot.mode"))
      case .firmware: named.append((.customFirmware, "boot.mode"))
      case .disk: break
      }
      if boot.haltAtStart { named.append((.haltAtStart, "boot.haltAtStart")) }
    }
    return named
  }

  private func validate() throws(VMLabError) {
    if case .other(let name) = guest.arch, name.isEmpty {
      throw .invalidRequest(
        field: "guest.arch", reason: "empty architecture",
        hint: "Use arm64, x86_64, riscv64 or another architecture name.")
    }
    for (field, value) in [
      ("resources.cpus", resources.cpus), ("resources.memoryGB", resources.memoryGB),
      ("resources.diskGB", resources.diskGB),
    ] {
      if let value, value <= 0 {
        throw .invalidRequest(
          field: field, reason: "must be positive, got \(value)",
          hint: "Give a positive number or leave the field out for the default.")
      }
    }
    for (index, forward) in network.forwards.enumerated() {
      for (name, port) in [("guest", forward.guest), ("host", forward.host)] {
        if let port, !(1...65535).contains(port) {
          throw .invalidRequest(
            field: "network.forwards[\(index)].\(name)", reason: "port \(port) is out of range",
            hint: "Use a port from 1 to 65535.")
        }
      }
    }
    if let boot {
      if boot.mode == .kernel, boot.kernel == nil {
        throw .invalidRequest(
          field: "boot.kernel", reason: "boot mode kernel needs a kernel",
          hint: "Give boot.kernel the path of the kernel image.")
      }
      if boot.mode == .firmware, boot.firmware == nil {
        throw .invalidRequest(
          field: "boot.firmware", reason: "boot mode firmware needs a firmware image",
          hint: "Give boot.firmware the path of the firmware image.")
      }
    }
    try checkContradictions()
  }

  private func checkContradictions() throws(VMLabError) {
    let named = namedFeatures
    if guest.os == .macos {
      for (feature, field) in named
      where [.directKernelBoot, .customFirmware, .serial].contains(feature) {
        throw .invalidRequest(
          field: field, reason: "a macOS guest cannot have \(feature.rawValue)",
          hint: "Drop \(feature.rawValue) or ask for a Linux guest.")
      }
    }
    if guest.os != .linux || guest.arch != .arm64,
      let hit = named.first(where: { $0.feature == .rosetta })
    {
      throw .invalidRequest(
        field: hit.field,
        reason: "rosetta needs an arm64 Linux guest, not "
          + "\(guest.os.rawValue)/\(guest.arch.rawValue)",
        hint: "Drop rosetta or ask for guest { os: linux, arch: arm64 }.")
    }
    if let none = named.first(where: { $0.feature == .netNone }),
      let hit = named.first(where: {
        [.netNAT, .netFast, .netPortForward, .netSegment].contains($0.feature)
      })
    {
      throw .invalidRequest(
        field: hit.field,
        reason: "\(hit.feature.rawValue) contradicts net_none (\(none.field))",
        hint: "Drop net_none or drop every other network feature.")
    }
  }
}
