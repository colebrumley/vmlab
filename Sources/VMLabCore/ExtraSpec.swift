import Foundation

/// Engine-specific additions to a request (R-306). `qemuArgs` are appended after vmlab's own QEMU
/// arguments; naming any implies `custom_devices`.
///
/// Every option is checked against `allowedQEMUOptions` (an option QEMU has that is not there is
/// refused, with the reason from `refusedQEMUOptions` when it is one vmlab owns or one that is
/// dangerous). Values are parsed as QEMU's `key=value,...` (`,,` an escaped comma). Refused
/// anywhere: `exec:`, `mon:` or `cmd:`, the JSON form of an option, a key that names a host file
/// descriptor, a helper or a script (`fd`, `script`, `smb`, ...), and a type off its option's
/// list. A host path (`file=`, `path=`, `romfile=`, ..., matched on the last dotted component, so
/// `file.filename=` too, and the bare value of `-D`, `-cdrom`, `-mem-path`, ...) must be absolute,
/// and `checkHostPaths` holds it to the R-1102 `PathPolicy` and out of vmlab's own home.
///
/// `-cpu` replaces vmlab's own CPU model and `-machine` (`-M`) properties merge into vmlab's
/// `-machine`; `QEMUCommandLine` holds both to the profile. Options and types that run host code
/// or pass host hardware through (`-plugin`, `-semihosting`, `usb-host`, `vfio-*`, `vhost-*`,
/// host serial and parallel chardevs, ...) are `hostCodeUses`: `checkHostPaths` refuses them
/// unless the owner set `"allowHostCode": true` in `VMLAB_HOME/config.json`.
public struct ExtraSpec: Codable, Sendable, Hashable {
  public var qemuArgs: [String]

  /// How one allowed QEMU option is checked.
  public struct OptionRule: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
      /// No value (`-usb`).
      case flag
      /// `key=value,...`.
      case options
      /// One word QEMU reads as it is (log items, a keyboard layout, a UUID).
      case free
      /// One absolute host path.
      case hostPath
    }

    public var value: Value
    /// The key a leading bare token stands for (`-chardev socket,...` is `backend=socket`).
    public var impliedKey: String?
    /// The values that key may take; nil allows any.
    public var types: Set<String>?
    /// Values of that key that are always refused.
    public var deniedTypes: Set<String>
    /// Values of that key that run host code or pass host hardware through (`allowHostCode`).
    public var hostCodeTypes: Set<String>
    /// Prefixes of such values (`vfio-`).
    public var hostCodePrefixes: [String]
    /// The option itself runs host code (`-plugin`).
    public var hostCode: Bool
    /// Bare `+feature` and `-feature` tokens are allowed after the first (`-cpu`).
    public var featureFlags: Bool
    /// The key the path of a `hostPath` option is reported under (`file` for a drive).
    public var pathKey: String

    public init(
      _ value: Value = .options, impliedKey: String? = nil, types: Set<String>? = nil,
      deniedTypes: Set<String> = [], hostCodeTypes: Set<String> = [],
      hostCodePrefixes: [String] = [], hostCode: Bool = false, featureFlags: Bool = false,
      pathKey: String = "path"
    ) {
      self.value = value
      self.impliedKey = impliedKey
      self.types = types
      self.deniedTypes = deniedTypes
      self.hostCodeTypes = hostCodeTypes
      self.hostCodePrefixes = hostCodePrefixes
      self.hostCode = hostCode
      self.featureFlags = featureFlags
      self.pathKey = pathKey
    }
  }

  static let netdevTypes: Set<String> = ["user", "socket", "stream", "dgram", "hubport"]
  /// Network backends served by a host daemon or a host device.
  static let netdevHostCodeTypes: Set<String> = ["vhost-user", "vhost-vdpa"]
  /// Network backends that need root or run a host helper; refused even with `allowHostCode`.
  static let netdevRootTypes: Set<String> = [
    "tap", "bridge", "vmnet-host", "vmnet-shared", "vmnet-bridged", "l2tpv3", "vde", "af-xdp",
    "netmap",
  ]
  /// Devices that pass host hardware or a host kernel/daemon service through.
  static let passthroughDevices: Set<String> = ["usb-host", "u2f-passthru", "ccid-card-emulated"]
  static let passthroughDevicePrefixes = ["vfio-", "vhost-"]

  /// The QEMU options a request may pass, by name.
  public static let allowedQEMUOptions: [String: OptionRule] = {
    let drive = OptionRule(.hostPath, pathKey: "file")
    let audio = OptionRule(
      impliedKey: "driver", types: ["none", "wav"], hostCodeTypes: ["coreaudio"])
    let fs = OptionRule(impliedKey: "fsdriver", types: ["local", "synth"])
    var rules: [String: OptionRule] = [
      "device": OptionRule(
        impliedKey: "driver", hostCodeTypes: passthroughDevices,
        hostCodePrefixes: passthroughDevicePrefixes),
      "global": OptionRule(),
      "drive": OptionRule(),
      "blockdev": OptionRule(),
      "object": OptionRule(
        impliedKey: "qom-type",
        // A host D-Bus peer, a host file descriptor, a socket other processes drive the device
        // through.
        deniedTypes: [
          "dbus-vmstate", "x-remote-object", "remote-object", "x-vfio-user-server",
          "vfio-user-server",
        ],
        hostCodeTypes: [
          "can-host-socketcan", "cryptodev-vhost-user", "memory-backend-epc", "input-linux",
          "secret_keyring", "authz-pam",
        ]),
      "chardev": OptionRule(
        impliedKey: "backend",
        types: [
          "socket", "udp", "null", "ringbuf", "memory", "file", "pipe", "pty", "msmouse",
          "wctablet", "testdev", "hub", "qemu-vdagent",
        ],
        hostCodeTypes: ["serial", "tty", "parallel", "parport", "braille"]),
      "netdev": OptionRule(
        impliedKey: "type", types: netdevTypes, deniedTypes: netdevRootTypes,
        hostCodeTypes: netdevHostCodeTypes),
      "nic": OptionRule(
        impliedKey: "type", types: netdevTypes.union(["none"]), deniedTypes: netdevRootTypes,
        hostCodeTypes: netdevHostCodeTypes),
      "net": OptionRule(
        impliedKey: "type", types: netdevTypes.union(["nic", "none"]),
        deniedTypes: netdevRootTypes, hostCodeTypes: netdevHostCodeTypes),
      "rtc": OptionRule(),
      "boot": OptionRule(impliedKey: "order"),
      "smbios": OptionRule(),
      "fw_cfg": OptionRule(impliedKey: "name"),
      "action": OptionRule(),
      "cpu": OptionRule(impliedKey: "model", featureFlags: true),
      "machine": OptionRule(impliedKey: "type"),
      "M": OptionRule(impliedKey: "type"),
      "icount": OptionRule(impliedKey: "shift"),
      "d": OptionRule(.free),
      "dfilter": OptionRule(.free),
      "D": OptionRule(.hostPath, pathKey: "logfile"),
      "trace": OptionRule(impliedKey: "enable"),
      "numa": OptionRule(
        impliedKey: "type", types: ["node", "dist", "cpu", "hmat-lb", "hmat-cache"]),
      "overcommit": OptionRule(),
      "mem-path": OptionRule(.hostPath, pathKey: "mem-path"),
      "option-rom": OptionRule(impliedKey: "romfile"),
      "acpitable": OptionRule(),
      "audiodev": audio,
      "audio": audio,
      "tpmdev": OptionRule(impliedKey: "type", types: ["emulator"], hostCodeTypes: ["passthrough"]),
      "vga": OptionRule(
        impliedKey: "type", types: ["none", "std", "cirrus", "vmware", "qxl", "virtio"]),
      "usbdevice": OptionRule(
        impliedKey: "driver", types: ["mouse", "tablet", "keyboard"], hostCodeTypes: ["braille"]),
      "virtfs": fs,
      "fsdev": fs,
      "iscsi": OptionRule(),
      "msg": OptionRule(),
      "compat": OptionRule(),
      "uuid": OptionRule(.free),
      "k": OptionRule(.free),
      "seed": OptionRule(.free),
      "watchdog-action": OptionRule(.free),
      "echr": OptionRule(.free),
      "dump-vmstate": OptionRule(.hostPath, pathKey: "dump-vmstate"),
      "plugin": OptionRule(impliedKey: "file", hostCode: true),
      "semihosting": OptionRule(.flag, hostCode: true),
      "semihosting-config": OptionRule(impliedKey: "enable", hostCode: true),
    ]
    for name in ["cdrom", "hda", "hdb", "hdc", "hdd", "fda", "fdb", "sd", "mtdblock"] {
      rules[name] = drive
    }
    for name in [
      "usb", "no-reboot", "no-shutdown", "mem-prealloc", "enable-sync-profile", "only-migratable",
      "no-fd-bootchk", "win2k-hack",
    ] {
      rules[name] = OptionRule(.flag)
    }
    return rules
  }()

  /// Why an option QEMU has is refused, and what to do instead.
  public struct Refusal: Sendable, Hashable {
    public var reason: String
    public var hint: String
  }

  /// The QEMU options refused with a reason of their own; any other unknown option gets a
  /// generic one.
  public static let refusedQEMUOptions: [String: Refusal] = {
    var refused: [String: Refusal] = [:]
    func add(_ names: [String], _ reason: String, _ hint: String) {
      for name in names { refused[name] = Refusal(reason: reason, hint: hint) }
    }
    add(
      ["qmp", "qmp-pretty", "monitor", "mon", "nographic"],
      "opens a QEMU monitor, which vmlab owns",
      "Drop it; use vm_introspect and vm_lifecycle, which drive vmlab's own QMP.")
    add(
      ["serial"], "vmlab owns -serial: it is the guest's console (vm_serial)",
      "For another serial port add -chardev socket,id=s1,path=/tmp/s1.sock,server=on,wait=off "
        + "with -device pci-serial,chardev=s1 (isa-serial on x86_64).")
    add(
      ["parallel", "debugcon"], "takes a legacy chardev string vmlab does not parse",
      "Add -chardev ...,id=c1 and a device on it, such as -device isa-parallel,chardev=c1 or "
        + "-device isa-debugcon,chardev=c1.")
    add(
      ["vnc", "display", "full-screen", "spice"], "vmlab owns the display (vm_computer)",
      "Drop it; add display devices with -device or -vga.")
    add(
      ["gdb", "s"], "vmlab owns the GDB stub", "Require gdb and use vm_debug.")
    add(
      ["kernel", "initrd", "append", "dtb", "bios", "L", "shim", "pflash"],
      "vmlab owns the firmware and boot images", "Use boot (mode kernel, firmware or binary).")
    add(
      ["smp", "m"], "vmlab sizes the guest", "Use resources.cpus and resources.memoryGB.")
    add(
      ["accel", "enable-kvm"], "the profile picks the accelerator",
      "Let the plan choose; an arm64 guest runs on qemu-hvf, other architectures on qemu-tcg.")
    add(
      [
        "name", "pidfile", "daemonize", "S", "preconfig", "nodefaults", "no-user-config",
        "run-with",
      ],
      "vmlab owns the QEMU process", "Drop it.")
    add(
      ["snapshot", "loadvm"], "vmlab owns the disk's state", "Use vm_checkpoint.")
    add(
      ["incoming"], "a migration stream can run a host command (exec:) or open a host descriptor",
      "Use vm_checkpoint to restore a guest's state.")
    add(
      ["add-fd"], "hands QEMU a host file descriptor", "Drop it.")
    add(
      ["sandbox"], "changes QEMU's own seccomp sandbox", "Drop it.")
    add(
      ["readconfig", "set"], "sets options past these checks",
      "Give each option as its own arguments.")
    add(
      ["xen-domid", "xen-attach", "xen-domid-restrict"], "there is no Xen on this host",
      "Drop it.")
    add(
      ["h", "help", "version"], "makes QEMU print and exit", "Drop it.")
    return refused
  }()

  /// Keys refused in any option value: host file descriptors (which could name QEMU's own
  /// sockets), and helpers or scripts QEMU would run on the host.
  public static let deniedKeys: Set<String> = [
    "fd", "fds", "vhostfd", "vhostfds", "sock_fd", "script", "downscript", "helper", "smb",
  ]

  /// `-machine` keys vmlab owns: the accelerator is the profile's, the boot images `boot`'s.
  static let machineOwnedKeys: [String: String] = [
    "accel": "Drop accel=; the profile picks the accelerator.",
    "kernel": "Use boot.kernel.", "initrd": "Use boot.initrd.", "append": "Use boot.cmdline.",
    "dtb": "Use boot.dtb.", "firmware": "Use boot.firmware.", "shim": "Use boot.",
  ]

  /// Keys whose value is a host path (matched on the last dotted component).
  public static let hostPathKeys: Set<String> = [
    "file", "filename", "path", "mem-path", "dir", "romfile", "splash", "evdev", "tftp", "logfile",
    "rrfile", "events", "dumpdtb", "cancel-path",
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

  /// One option in the arguments (they have passed `validate()`): its index, name and value.
  struct Option {
    var index: Int
    var name: String
    var rule: OptionRule
    var value: String?
    var valueIndex: Int { index + 1 }
  }

  /// The options in order; stops at the first one `validate()` would refuse.
  var options: [Option] {
    var result: [Option] = []
    var index = 0
    while index < qemuArgs.count {
      guard let name = Self.optionName(qemuArgs[index]), let rule = Self.allowedQEMUOptions[name]
      else { break }
      if rule.value != .flag, index + 1 < qemuArgs.count {
        result.append(Option(index: index, name: name, rule: rule, value: qemuArgs[index + 1]))
        index += 2
      } else {
        result.append(Option(index: index, name: name, rule: rule, value: nil))
        index += 1
      }
    }
    return result
  }

  /// One host path a value names: the argument's index, its key and the path.
  public struct HostPath: Sendable, Hashable {
    public var index: Int
    public var key: String
    public var path: String
  }

  /// Every host path the arguments name (they have passed `validate()`).
  public var hostPaths: [HostPath] {
    options.flatMap { option -> [HostPath] in
      guard let value = option.value else { return [] }
      if option.rule.value == .hostPath {
        return [HostPath(index: option.valueIndex, key: option.rule.pathKey, path: value)]
      }
      guard option.rule.value == .options else { return [] }
      return Self.pairs(option: option.name, value: value, rule: option.rule).flatMap {
        pair -> [HostPath] in
        guard let key = pair.key else { return [] }
        return Self.paths(option: option.name, key: key, value: pair.value).map {
          HostPath(index: option.valueIndex, key: key, path: $0)
        }
      }
    }
  }

  /// One use of host code or host hardware: the argument's index and what it is.
  public struct HostCodeUse: Sendable, Hashable {
    public var index: Int
    public var what: String
  }

  /// The options and types that need `allowHostCode` (the arguments have passed `validate()`).
  public var hostCodeUses: [HostCodeUse] {
    options.compactMap { option -> HostCodeUse? in
      if option.rule.hostCode { return HostCodeUse(index: option.index, what: "-" + option.name) }
      guard let value = option.value, option.rule.value == .options,
        let type = Self.type(
          of: Self.pairs(option: option.name, value: value, rule: option.rule),
          rule: option.rule),
        Self.isHostCode(type, rule: option.rule)
      else { return nil }
      return HostCodeUse(index: option.valueIndex, what: "-\(option.name) \(type)")
    }
  }

  /// The request's `-cpu` value and its index; it replaces vmlab's own.
  public var cpu: (index: Int, value: String)? {
    options.last { $0.name == "cpu" }.flatMap { o in o.value.map { (o.valueIndex, $0) } }
  }

  /// The board the request's `-machine` names, with its index; nil keeps vmlab's.
  public var machineType: (index: Int, value: String)? {
    var found: (Int, String)?
    for option in options where option.name == "machine" || option.name == "M" {
      guard let value = option.value else { continue }
      if let type = Self.pairs(option: option.name, value: value, rule: option.rule)
        .first(where: { $0.key == "type" })?.value
      {
        found = (option.valueIndex, type)
      }
    }
    return found
  }

  /// The request's `-machine` properties other than the board, in order and re-escaped, for
  /// vmlab's own `-machine`.
  public var machineProperties: [String] {
    options.filter { $0.name == "machine" || $0.name == "M" }.flatMap { option -> [String] in
      guard let value = option.value else { return [] }
      return Self.pairs(option: option.name, value: value, rule: option.rule).compactMap {
        pair in
        guard let key = pair.key, key != "type" else { return nil }
        return key + "=" + pair.value.replacingOccurrences(of: ",", with: ",,")
      }
    }
  }

  /// Whether the arguments name `-icount` (which needs TCG).
  public var usesICount: Bool { options.contains { $0.name == "icount" } }

  /// The arguments appended after vmlab's own: everything but `-cpu` and `-machine`, which go
  /// into vmlab's own options instead.
  public var appendedArguments: [String] {
    options.filter { !["cpu", "machine", "M"].contains($0.name) }.flatMap { option in
      [qemuArgs[option.index]] + (option.value.map { [$0] } ?? [])
    }
  }

  static func lastComponent(_ key: String) -> String {
    String(key.split(separator: ".", omittingEmptySubsequences: false).last ?? Substring(key))
  }

  static func isHostPathKey(_ key: String) -> Bool { hostPathKeys.contains(lastComponent(key)) }

  /// The host paths one pair names: none for another key, one for a path key, and each of the
  /// colon-separated list of `-acpitable file=` and `data=`.
  static func paths(option: String, key: String, value: String) -> [String] {
    if option == "acpitable", ["file", "data"].contains(key) {
      return value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    }
    return isHostPathKey(key) ? [value] : []
  }

  /// The pairs of `option`'s `value`, the leading bare token keyed by the rule's implied key.
  /// `-global d.p=v` is one pair whose value runs to the end (commas included), as QEMU reads it.
  static func pairs(option: String, value: String, rule: OptionRule) -> Pairs {
    if option == "global", let eq = value.firstIndex(of: "="),
      value[..<eq].contains("."), !value[..<eq].contains(",")
    {
      return [(String(value[..<eq]), String(value[value.index(after: eq)...]))]
    }
    var pairs = normalised(parseOptions(value))
    if let implied = rule.impliedKey, let first = pairs.first, first.key == nil {
      pairs[0] = (implied, first.value)
    }
    return pairs
  }

  /// `-global driver=d,property=p,value=v` is `d.p=v`; other pairs are as given.
  typealias Pairs = [(key: String?, value: String)]

  static func normalised(_ pairs: Pairs) -> Pairs {
    guard let property = pairs.first(where: { $0.key == "property" })?.value,
      let value = pairs.first(where: { $0.key == "value" })?.value
    else { return pairs }
    return pairs.filter { $0.key != "property" && $0.key != "value" } + [(property, value)]
  }

  static func type(of pairs: Pairs, rule: OptionRule) -> String? {
    guard let implied = rule.impliedKey else { return nil }
    return pairs.first(where: { $0.key == implied })?.value
  }

  static func isHostCode(_ type: String, rule: OptionRule) -> Bool {
    rule.hostCodeTypes.contains(type) || rule.hostCodePrefixes.contains { type.hasPrefix($0) }
  }

  /// Throws `invalid_request` naming the first argument that is not allowed. Host-code options
  /// pass here; `checkHostPaths` refuses them without the owner's `allowHostCode`.
  public func validate() throws(VMLabError) {
    func refuse(_ index: Int, _ reason: String, _ hint: String) -> VMLabError {
      .invalidRequest(field: "extra.qemuArgs[\(index)]", reason: reason, hint: hint)
    }
    var index = 0
    var cpuSeen = false
    while index < qemuArgs.count {
      let argument = qemuArgs[index]
      guard let name = Self.optionName(argument) else {
        throw refuse(
          index, "\(argument) is a value with no option before it",
          "Give each value right after its option, such as [\"-device\", \"virtio-rng-pci\"].")
      }
      guard !argument.contains("=") else {
        throw refuse(
          index, "\(argument) gives its value after =",
          "Give the value as the next argument, such as [\"-\(name)\", \"...\"].")
      }
      guard let rule = Self.allowedQEMUOptions[name] else {
        if let refusal = Self.refusedQEMUOptions[name] {
          throw refuse(index, "\(argument) is not allowed: \(refusal.reason)", refusal.hint)
        }
        throw refuse(
          index, "\(argument) is not an option vmlab passes to QEMU",
          "See the custom_devices section of docs/AGENT.md for the options extra.qemuArgs takes.")
      }
      if name == "cpu" {
        if cpuSeen {
          throw refuse(index, "-cpu is given twice", "Give one -cpu with every feature on it.")
        }
        cpuSeen = true
      }
      guard rule.value != .flag else {
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
    switch rule.value {
    case .flag, .free: return
    case .hostPath:
      guard value.hasPrefix("/") else {
        throw refuse(
          "\(value) after \(option) is not an absolute host path",
          "Give an absolute path under your home directory or /tmp.")
      }
      return
    case .options: break
    }
    let pairs = pairs(option: name, value: value, rule: rule)
    if let impliedKey = rule.impliedKey {
      // QEMU reads the last of a repeated key, these checks the first: one of each.
      if pairs.count(where: { $0.key == impliedKey }) > 1 {
        throw refuse(
          "\(value) gives \(impliedKey) more than once", "Give \(impliedKey) once.")
      }
      let type = Self.type(of: pairs, rule: rule)
      if let type, rule.deniedTypes.contains(type) {
        throw refuse(
          "\(option) \(type) needs root, a host helper, a host descriptor or a host daemon",
          "Use an emulated device or user-mode networking instead.")
      }
      if let types = rule.types, !types.contains(type ?? ""),
        !(type.map { isHostCode($0, rule: rule) } ?? false)
      {
        throw refuse(
          "\(option) \(type ?? "with no \(impliedKey)") is not allowed",
          "Use one of: \(types.sorted().joined(separator: ", ")).")
      }
    }
    if name == "cpu", let model = pairs.first?.value,
      pairs.first?.key != "model" || model.isEmpty || model.hasPrefix("+") || model.hasPrefix("-")
    {
      throw refuse(
        "\(value) after -cpu does not start with a CPU model",
        "Give the model first, then its features, such as max,sve=on or host,pmu=off.")
    }
    for (position, pair) in pairs.enumerated() {
      guard let key = pair.key else {
        if rule.featureFlags, position > 0, pair.value.count > 1,
          pair.value.hasPrefix("+") || pair.value.hasPrefix("-")
        {
          continue
        }
        throw refuse(
          "\(pair.value) in \(option) has no key", "Write every part of the value as key=value.")
      }
      if deniedKeys.contains(lastComponent(key)) {
        throw refuse(
          "\(key)= in \(option) hands QEMU a host file descriptor, helper or script",
          "Drop \(key)=.")
      }
      // A socket address of type fd names one of QEMU's own descriptors (its QMP sockets).
      if lastComponent(key) == "type", pair.value == "fd" {
        throw refuse(
          "\(key)=fd in \(option) hands QEMU a host file descriptor",
          "Use a unix socket path or an inet address instead.")
      }
      if name == "machine" || name == "M", let hint = machineOwnedKeys[key] {
        throw refuse("\(key)= in \(option) is vmlab's to set", hint)
      }
      for path in paths(option: name, key: key, value: pair.value) where !path.hasPrefix("/") {
        throw refuse(
          "\(key)=\(pair.value) in \(option) is not an absolute host path",
          "Give an absolute path under your home directory or /tmp.")
      }
    }
  }

  /// One host path through `policy` and out of vmlab's own home (whose VM directories hold
  /// every guest's QMP, serial and VNC sockets and disks); its canonical form.
  public static func checkHostPath(
    _ path: String, field: String, policy: PathPolicy, vmlabHome: URL
  ) throws(VMLabError) -> String {
    let protected = PathPolicy.canonical(vmlabHome.path)
    let resolved = try policy.check(path, field: field).path
    if PathPolicy.isInside(resolved, protected) {
      throw .invalidRequest(
        field: field, reason: "\(path) is inside vmlab's own home (\(protected))",
        hint: "Use a path outside VMLAB_HOME; vmlab's VM directories are its own.")
    }
    return resolved
  }

  /// Throws `invalid_request` for a host-code option or type unless `allowHostCode` (the owner's
  /// `VMLAB_HOME/config.json`, never a tool argument), then for a host path the arguments name
  /// that `policy` refuses, that lies inside `vmlabHome`, or that is an existing unix socket.
  public func checkHostPaths(
    policy: PathPolicy, vmlabHome: URL, allowHostCode: Bool
  ) throws(VMLabError) {
    if !allowHostCode, let use = hostCodeUses.first {
      throw .invalidRequest(
        field: "extra.qemuArgs[\(use.index)]",
        reason: "\(use.what) runs host code or passes host hardware through to the guest",
        hint: "Drop it, or have the owner set \"allowHostCode\": true in "
          + VMLabConfig.url(home: vmlabHome).path + ".")
    }
    for hostPath in hostPaths where !Self.harmlessHostPaths.contains(hostPath.path) {
      let field = "extra.qemuArgs[\(hostPath.index)]"
      let resolved = try Self.checkHostPath(
        hostPath.path, field: field, policy: policy, vmlabHome: vmlabHome)
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
