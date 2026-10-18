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

/// How a guest boots (R-305). `disk` boots the image through UEFI; `kernel` loads a kernel,
/// initrd and optional device tree directly (`kernel: nil` takes the image's extracted or
/// registered kernel); `firmware` supplies the firmware itself, as a pflash image or a `-bios`
/// ROM; `binary` loads a raw image at `loadAddress` and starts the first CPU there.
public struct BootSpec: Codable, Sendable, Hashable {
  public enum Mode: String, CaseIterable, Codable, Sendable {
    case disk, kernel, firmware, binary
  }

  /// How a `firmware` image is attached: a flash device (UEFI builds) or a ROM.
  public enum FirmwareFormat: String, CaseIterable, Codable, Sendable {
    case pflash, bios
  }

  public var mode: Mode
  public var kernel: String?
  public var initrd: String?
  public var cmdline: String?
  public var dtb: String?
  public var firmware: String?
  public var firmwareFormat: FirmwareFormat
  public var binary: String?
  /// Where `binary` is loaded: hex (`0x40080000`) or decimal.
  public var loadAddress: String?
  public var haltAtStart: Bool

  public init(
    mode: Mode = .disk, kernel: String? = nil, initrd: String? = nil, cmdline: String? = nil,
    dtb: String? = nil, firmware: String? = nil, firmwareFormat: FirmwareFormat = .pflash,
    binary: String? = nil, loadAddress: String? = nil, haltAtStart: Bool = false
  ) {
    self.mode = mode
    self.kernel = kernel
    self.initrd = initrd
    self.cmdline = cmdline
    self.dtb = dtb
    self.firmware = firmware
    self.firmwareFormat = firmwareFormat
    self.binary = binary
    self.loadAddress = loadAddress
    self.haltAtStart = haltAtStart
  }

  enum CodingKeys: String, CodingKey {
    case mode, kernel, initrd, cmdline, dtb, firmware, firmwareFormat, binary, loadAddress
    case haltAtStart
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .disk
    kernel = try c.decodeIfPresent(String.self, forKey: .kernel)
    initrd = try c.decodeIfPresent(String.self, forKey: .initrd)
    cmdline = try c.decodeIfPresent(String.self, forKey: .cmdline)
    dtb = try c.decodeIfPresent(String.self, forKey: .dtb)
    firmware = try c.decodeIfPresent(String.self, forKey: .firmware)
    firmwareFormat =
      try c.decodeIfPresent(FirmwareFormat.self, forKey: .firmwareFormat) ?? .pflash
    binary = try c.decodeIfPresent(String.self, forKey: .binary)
    loadAddress = try c.decodeIfPresent(String.self, forKey: .loadAddress)
    haltAtStart = try c.decodeIfPresent(Bool.self, forKey: .haltAtStart) ?? false
  }

  /// `loadAddress` as a number, accepting `0x` hex or decimal; nil when absent or malformed.
  public var parsedLoadAddress: UInt64? {
    guard let text = loadAddress?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
      return nil
    }
    let lower = text.lowercased()
    if lower.hasPrefix("0x") { return UInt64(lower.dropFirst(2), radix: 16) }
    return UInt64(lower)
  }
}

/// The host directory a request shares into the guest (R-404, `share`; implies `shared_dir`),
/// mounted read-write at `guest` (default `/mnt/host`): 9p under QEMU, virtiofs under VZ (R-603).
/// A request that requires `shared_dir` without `share` gets the VM's own `<vm>/shared/`.
public struct SharedDirSpec: Codable, Sendable, Hashable {
  public static let defaultGuestPath = "/mnt/host"
  /// The device tag both engines use.
  public static let tag = "share0"

  /// An absolute host path of an existing directory; nil is `<vm>/shared/`.
  public var host: String?
  /// An absolute guest path (no whitespace: it is an fstab field).
  public var guest: String?

  public init(host: String? = nil, guest: String? = nil) {
    self.host = host
    self.guest = guest
  }

  public var guestPath: String { guest ?? Self.defaultGuestPath }

  /// Where a macOS guest mounts the share by itself (CX-27: the automount virtiofs tag); a
  /// `vz-macos` share is always there.
  public static let macOSAutomountPath = "/Volumes/My Shared Files"

  /// The guest path the share is mounted at under `profile`.
  public func guestPath(for profile: Profile) -> String {
    profile == .vzMacOS ? Self.macOSAutomountPath : guestPath
  }

  /// The host directory of a VM whose directory is `vmDirectory`.
  public func hostDirectory(vmDirectory: URL) -> URL {
    host.map { URL(filePath: $0).standardizedFileURL }
      ?? vmDirectory.appending(path: "shared", directoryHint: .isDirectory)
  }

  /// The share `record` mounts, or nil: the request's `share`, or the default one when the
  /// request asked for `shared_dir` (granting it alone, as every profile does, mounts nothing).
  public static func of(_ record: VMRecord) -> SharedDirSpec? {
    if let share = record.share { return share }
    guard record.plan?.requests(.sharedDir) == true, record.features.contains(.sharedDir) else {
      return nil
    }
    return SharedDirSpec()
  }

  /// Throws `invalid_request` for a relative path or a guest path an fstab line cannot hold.
  public func validate() throws(VMLabError) {
    if let host {
      guard host.hasPrefix("/"), !host.contains("\n"), !host.contains("\0") else {
        throw .invalidRequest(
          field: "share.host", reason: "\(host) is not an absolute path",
          hint: "Give the absolute path of a host directory, such as /Users/me/project.")
      }
    }
    if let guest {
      let bad = guest.unicodeScalars.contains {
        $0.properties.isWhitespace || $0.value < 0x20 || $0 == "\\" || $0 == "\""
      }
      guard guest.hasPrefix("/"), guest != "/", !bad else {
        throw .invalidRequest(
          field: "share.guest",
          reason: "\(guest) is not an absolute guest path without spaces, quotes or backslashes",
          hint: "Use a path such as /mnt/host.")
      }
    }
  }

  /// Throws `invalid_request` unless the host directory exists (checked at create and start).
  public func checkHostDirectory(vmDirectory: URL) throws(VMLabError) {
    let url = hostDirectory(vmDirectory: vmDirectory)
    if host == nil {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw .invalidRequest(
        field: "share.host", reason: "\(url.path) is not an existing directory",
        hint: "Create the directory first, or give the path of one that exists.")
    }
  }
}

/// Engine-specific additions to a request (R-306). `qemuArgs` are appended verbatim after
/// vmlab's own QEMU arguments; naming any implies `custom_devices`.
///
/// The surface is an allowlist (bug hunt BH-1: a denylist kept leaking host code execution, such
/// as `-incoming exec:` and HMP monitors on `mon:` chardevs). Only the options in
/// `allowedQEMUOptions` may appear, each value is parsed as QEMU's `key=value,...` (`,,` an
/// escaped comma), and anything else is `invalid_request`: an unknown option, a stray value, the
/// JSON form of an option, `exec:`, `mon:` or `cmd:` anywhere, a key that names a host file
/// descriptor, a helper or a script (`fd`, `script`, `smb`, ...), a chardev or netdev type that is
/// not on its list, and a host-passthrough device. A host path (`file=`, `path=`, `romfile=`, ...,
/// matched on the last dotted component, so `file.filename=` too) must be absolute here, and
/// `checkHostPaths` holds it to the R-1102 `PathPolicy` and out of vmlab's own home.
public struct ExtraSpec: Codable, Sendable, Hashable {
  public var qemuArgs: [String]

  /// How one allowed QEMU option is checked.
  public struct OptionRule: Sendable, Hashable {
    /// The option takes the next argument as its value.
    public var takesValue: Bool
    /// The key a leading bare token stands for (`-chardev socket,...` is `backend=socket`).
    public var impliedKey: String?
    /// The values that key may take; nil allows any.
    public var types: Set<String>?
    /// Values of that key that are refused (host passthrough).
    public var deniedTypes: Set<String>

    public init(
      takesValue: Bool = true, impliedKey: String? = nil, types: Set<String>? = nil,
      deniedTypes: Set<String> = []
    ) {
      self.takesValue = takesValue
      self.impliedKey = impliedKey
      self.types = types
      self.deniedTypes = deniedTypes
    }
  }

  static let netdevTypes: Set<String> = ["user", "socket", "stream", "dgram", "hubport"]

  /// The QEMU options a request may pass, by name. vmlab owns the machine, CPU, memory, boot
  /// firmware, monitors, serial, display, GDB and process options; host-facing options that run
  /// commands or reach outside the guest (`-incoming`, `-add-fd`, `-sandbox`, `-plugin`, `-set`,
  /// `-readconfig`, `-virtfs`, `-fsdev`, `-trace`, `-D`, `-L`, `-bios`, `-kernel`, ...) are not here.
  public static let allowedQEMUOptions: [String: OptionRule] = [
    "device": OptionRule(
      impliedKey: "driver",
      deniedTypes: ["usb-host", "u2f-passthru", "vfio-pci", "vfio-platform", "vhost-user-fs-pci"]),
    "global": OptionRule(),
    "drive": OptionRule(),
    "blockdev": OptionRule(),
    "object": OptionRule(impliedKey: "qom-type"),
    "chardev": OptionRule(
      impliedKey: "backend",
      types: [
        "socket", "udp", "null", "ringbuf", "memory", "file", "pipe", "pty", "msmouse", "wctablet",
        "testdev",
      ]),
    "netdev": OptionRule(impliedKey: "type", types: netdevTypes),
    "nic": OptionRule(impliedKey: "type", types: netdevTypes.union(["none"])),
    "rtc": OptionRule(),
    "boot": OptionRule(impliedKey: "order"),
    "smbios": OptionRule(),
    "fw_cfg": OptionRule(impliedKey: "name"),
    "action": OptionRule(),
    "usb": OptionRule(takesValue: false),
    "no-reboot": OptionRule(takesValue: false),
    "no-shutdown": OptionRule(takesValue: false),
  ]

  /// Keys refused in any option value: host file descriptors (which could name QEMU's own
  /// sockets), and helpers or scripts QEMU would run on the host.
  public static let deniedKeys: Set<String> = [
    "fd", "fds", "vhostfd", "vhostfds", "script", "downscript", "helper", "smb",
  ]

  /// Keys whose value is a host path (matched on the last dotted component).
  public static let hostPathKeys: Set<String> = [
    "file", "filename", "path", "mem-path", "dir", "romfile", "splash", "evdev", "tftp", "logfile",
  ]

  /// Substrings refused anywhere in an argument: a command QEMU runs (`exec:` migration,
  /// `guestfwd=...-cmd:`) or an HMP monitor multiplexed onto a chardev (`mon:`).
  static let deniedFragments = ["exec:", "mon:", "cmd:"]

  /// Host paths that are allowed though outside the policy's roots.
  static let harmlessHostPaths: Set<String> = ["/dev/urandom", "/dev/random", "/dev/null"]

  public init(qemuArgs: [String] = []) { self.qemuArgs = qemuArgs }

  enum CodingKeys: String, CodingKey { case qemuArgs }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    qemuArgs = try c.decodeIfPresent([String].self, forKey: .qemuArgs) ?? []
  }

  /// The option name of a QEMU argument (`-device` → `device`, `--gdb=x` → `gdb`), or nil for a
  /// value.
  public static func optionName(_ argument: String) -> String? {
    guard argument.hasPrefix("-"), argument.count > 1 else { return nil }
    var name = argument.dropFirst()
    if name.hasPrefix("-") { name = name.dropFirst() }
    return String(name.prefix { $0 != "=" })
  }

  /// Splits a QEMU option value into `(key, value)` pairs as QEMU's opts parser does: `,` ends a
  /// pair, `,,` is a literal comma, and a token without `=` has a nil key.
  public static func parseOptions(_ value: String) -> [(key: String?, value: String)] {
    var tokens: [String] = []
    var current = ""
    var chars = Array(value)[...]
    while let c = chars.popFirst() {
      if c == "," {
        if chars.first == "," {
          current.append(",")
          chars.removeFirst()
        } else {
          tokens.append(current)
          current = ""
        }
      } else {
        current.append(c)
      }
    }
    tokens.append(current)
    return tokens.map { token in
      guard let eq = token.firstIndex(of: "=") else { return (nil, token) }
      return (String(token[..<eq]), String(token[token.index(after: eq)...]))
    }
  }

  /// One host path a value names: the argument's index, its key and the path.
  public struct HostPath: Sendable, Hashable {
    public var index: Int
    public var key: String
    public var path: String
  }

  /// Every host path the arguments name (they have passed `validate()`).
  public var hostPaths: [HostPath] {
    var result: [HostPath] = []
    var index = 0
    while index < qemuArgs.count {
      guard let name = Self.optionName(qemuArgs[index]), let rule = Self.allowedQEMUOptions[name]
      else { break }
      if rule.takesValue, index + 1 < qemuArgs.count {
        for pair in Self.pairs(option: name, value: qemuArgs[index + 1])
        where pair.key.map(Self.isHostPathKey) == true {
          result.append(HostPath(index: index + 1, key: pair.key!, path: pair.value))
        }
        index += 2
      } else {
        index += 1
      }
    }
    return result
  }

  static func lastComponent(_ key: String) -> String {
    String(key.split(separator: ".", omittingEmptySubsequences: false).last ?? Substring(key))
  }

  static func isHostPathKey(_ key: String) -> Bool { hostPathKeys.contains(lastComponent(key)) }

  /// The pairs of `option`'s `value`. `-global d.p=v` is one pair whose value runs to the end
  /// (commas included), as QEMU reads it.
  static func pairs(option: String, value: String) -> [(key: String?, value: String)] {
    if option == "global", let eq = value.firstIndex(of: "="),
      value[..<eq].contains("."), !value[..<eq].contains(",")
    {
      return [(String(value[..<eq]), String(value[value.index(after: eq)...]))]
    }
    return normalised(parseOptions(value))
  }

  /// `-global driver=d,property=p,value=v` is `d.p=v`; other pairs are as given.
  typealias Pairs = [(key: String?, value: String)]

  static func normalised(_ pairs: Pairs) -> Pairs {
    guard let property = pairs.first(where: { $0.key == "property" })?.value,
      let value = pairs.first(where: { $0.key == "value" })?.value
    else { return pairs }
    return pairs.filter { $0.key != "property" && $0.key != "value" } + [(property, value)]
  }

  /// Throws `invalid_request` naming the first argument that is not allowed.
  public func validate() throws(VMLabError) {
    func refuse(_ index: Int, _ reason: String, _ hint: String) -> VMLabError {
      .invalidRequest(field: "extra.qemuArgs[\(index)]", reason: reason, hint: hint)
    }
    let allowed = Self.allowedQEMUOptions.keys.sorted().map { "-" + $0 }.joined(separator: ", ")
    var index = 0
    while index < qemuArgs.count {
      let argument = qemuArgs[index]
      guard let name = Self.optionName(argument) else {
        throw refuse(
          index, "\(argument) is a value with no option before it",
          "Give each value right after its option, such as [\"-device\", \"virtio-rng-pci\"].")
      }
      guard let rule = Self.allowedQEMUOptions[name], !argument.contains("=") else {
        throw refuse(
          index, "\(argument) is managed by vmlab or not allowed through extra.qemuArgs",
          "Drop \(argument); vmlab already wires QMP, serial, VNC, GDB, firmware and the process "
            + "(use the vm_serial, vm_computer and vm_debug tools). Allowed: \(allowed).")
      }
      guard rule.takesValue else {
        index += 1
        continue
      }
      guard index + 1 < qemuArgs.count else {
        throw refuse(index, "\(argument) needs a value", "Give the value as the next argument.")
      }
      try Self.check(
        value: qemuArgs[index + 1], rule: rule, name: name, option: argument, index: index + 1)
      index += 2
    }
  }

  static func check(value: String, rule: OptionRule, name: String, option: String, index: Int)
    throws(VMLabError)
  {
    func refuse(_ reason: String, _ hint: String) -> VMLabError {
      .invalidRequest(field: "extra.qemuArgs[\(index)]", reason: reason, hint: hint)
    }
    if let fragment = deniedFragments.first(where: { value.contains($0) }) {
      throw refuse(
        "\(value) contains \(fragment), which makes QEMU run a host command or open a monitor",
        "Drop it; vmlab owns the monitors and runs no host commands for a guest.")
    }
    if value.hasPrefix("{") {
      throw refuse(
        "the JSON form of \(option) is not accepted", "Give it as key=value,key=value.")
    }
    let pairs = pairs(option: name, value: value)
    if let impliedKey = rule.impliedKey {
      let type =
        pairs.first.flatMap { $0.key == nil ? $0.value : nil }
        ?? pairs.first(where: { $0.key == impliedKey })?.value
      if let types = rule.types, !types.contains(type ?? "") {
        throw refuse(
          "\(option) \(type ?? "with no \(impliedKey)") is not allowed",
          "Use one of: \(types.sorted().joined(separator: ", ")).")
      }
      if let type, rule.deniedTypes.contains(type) {
        throw refuse(
          "\(option) \(type) reaches host hardware or a host daemon",
          "Use an emulated device instead.")
      }
    }
    for (position, pair) in pairs.enumerated() {
      guard let key = pair.key else {
        if position == 0, rule.impliedKey != nil { continue }
        throw refuse(
          "\(pair.value) in \(option) has no key", "Write every part of the value as key=value.")
      }
      if deniedKeys.contains(lastComponent(key)) {
        throw refuse(
          "\(key)= in \(option) hands QEMU a host file descriptor, helper or script",
          "Drop \(key)=.")
      }
      if isHostPathKey(key), !pair.value.hasPrefix("/") {
        throw refuse(
          "\(key)=\(pair.value) in \(option) is not an absolute host path",
          "Give an absolute path under your home directory or /tmp.")
      }
    }
  }

  /// Throws `invalid_request` for a host path the arguments name that `policy` refuses or that
  /// lies inside `vmlabHome` (whose VM directories hold every guest's QMP, serial and VNC
  /// sockets and disks).
  public func checkHostPaths(policy: PathPolicy, vmlabHome: URL) throws(VMLabError) {
    let protected = PathPolicy.canonical(vmlabHome.path)
    for hostPath in hostPaths where !Self.harmlessHostPaths.contains(hostPath.path) {
      let field = "extra.qemuArgs[\(hostPath.index)]"
      let resolved = try policy.check(hostPath.path, field: field).path
      if PathPolicy.isInside(resolved, protected) {
        throw .invalidRequest(
          field: field, reason: "\(hostPath.path) is inside vmlab's own home (\(protected))",
          hint: "Use a path outside VMLAB_HOME; vmlab's VM directories are its own.")
      }
      // A chardev or netdev client on an existing unix socket would hand the guest a host
      // service (an ssh or Docker agent); a server socket QEMU creates does not exist yet.
      var info = stat()
      if stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK {
        throw .invalidRequest(
          field: field, reason: "\(hostPath.path) is an existing host unix socket",
          hint: "Let QEMU create the socket (server=on) at a new path instead.")
      }
    }
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
  public var extra: ExtraSpec?
  /// First-boot packages, user-data and commands (R-1001).
  public var provision: ProvisionSpec?
  /// A host directory to mount in the guest (R-404); implies `shared_dir`.
  public var share: SharedDirSpec?

  /// Builds a request and checks it as decoding would.
  public init(
    guest: GuestSpec, require: [Feature] = [], prefer: [Feature] = [],
    resources: ResourceSpec = ResourceSpec(), network: NetworkSpec = NetworkSpec(),
    image: String? = nil, boot: BootSpec? = nil, extra: ExtraSpec? = nil,
    provision: ProvisionSpec? = nil, share: SharedDirSpec? = nil
  ) throws(VMLabError) {
    self.guest = guest
    self.require = require
    self.prefer = prefer
    self.resources = resources
    self.network = network
    self.image = image
    self.boot = boot
    self.extra = extra
    self.provision = provision
    self.share = share
    try validate()
  }

  enum CodingKeys: String, CodingKey {
    case guest, require, prefer, resources, network, image, boot, extra, provision, share
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
    extra = try c.decodeIfPresent(ExtraSpec.self, forKey: .extra)
    provision = try c.decodeIfPresent(ProvisionSpec.self, forKey: .provision)
    share = try c.decodeIfPresent(SharedDirSpec.self, forKey: .share)
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
      case .firmware, .binary: named.append((.customFirmware, "boot.mode"))
      case .disk: break
      }
      if boot.haltAtStart { named.append((.haltAtStart, "boot.haltAtStart")) }
    }
    if let extra, !extra.qemuArgs.isEmpty {
      named.append((.customDevices, "extra.qemuArgs"))
    }
    if let provision, !provision.isEmpty {
      // Linux provisioning is the seed's; macOS commands go over SSH.
      if guest.os == .macos {
        if !provision.runCommands.isEmpty { named.append((.execSSH, "provision.runCommands")) }
      } else {
        named.append((.cloudInit, "provision"))
      }
    }
    if share != nil { named.append((.sharedDir, "share")) }
    return named
  }

  private func validate() throws(VMLabError) {
    if let image { try ImageStore.checkName(image, field: "image") }
    if case .other(let name) = guest.arch, name.isEmpty {
      throw .invalidRequest(
        field: "guest.arch", reason: "empty architecture",
        hint: "Use arm64, x86_64, riscv64 or another architecture name.")
    }
    for (field, value, cap) in [
      ("resources.cpus", resources.cpus, ResourceLimits.maxCPUs),
      ("resources.memoryGB", resources.memoryGB, ResourceLimits.maxMemoryGB),
      ("resources.diskGB", resources.diskGB, ResourceLimits.maxDiskGB),
    ] {
      if let value, value <= 0 {
        throw .invalidRequest(
          field: field, reason: "must be positive, got \(value)",
          hint: "Give a positive number or leave the field out for the default.")
      }
      if let value, value > cap {
        throw .invalidRequest(
          field: field, reason: "\(value) is more than the limit of \(cap)",
          hint: "Ask for at most \(cap), or leave the field out for the default.")
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
      if boot.mode == .firmware, boot.firmware == nil {
        throw .invalidRequest(
          field: "boot.firmware", reason: "boot mode firmware needs a firmware image",
          hint: "Give boot.firmware the path of the firmware image.")
      }
      if boot.mode == .binary, boot.binary == nil {
        throw .invalidRequest(
          field: "boot.binary", reason: "boot mode binary needs a binary image",
          hint: "Give boot.binary the path of the raw image to load.")
      }
      if boot.mode == .binary, boot.parsedLoadAddress == nil {
        throw .invalidRequest(
          field: "boot.loadAddress",
          reason: boot.loadAddress.map { "\"\($0)\" is not an address" }
            ?? "boot mode binary needs a load address",
          hint: "Give boot.loadAddress in hex, such as \"0x40080000\".")
      }
    }
    try extra?.validate()
    try provision?.validate(guest: guest)
    try share?.validate()
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
