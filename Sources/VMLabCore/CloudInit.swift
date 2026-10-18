import Foundation

/// The guest's serial console device: `ttyAMA0` on QEMU's `virt` PL011, `hvc0` on a virtio console
/// (Virtualization.framework).
public enum ConsoleDevice: String, Codable, Sendable, CaseIterable {
  case ttyAMA0
  case hvc0
}

/// The desktop and VNC server installed when `gui` is granted to a Linux guest (R-504).
public struct GUIStack: Codable, Sendable, Hashable {
  /// The VNC password written to the server's password file.
  public var vncPassword: String
  /// The TCP port the VNC server listens on inside the guest.
  public var vncPort: Int

  public init(vncPassword: String, vncPort: Int = 5900) {
    self.vncPassword = vncPassword
    self.vncPort = vncPort
  }

  /// The Debian packages of the minimal desktop.
  public static let packages = ["xfce4", "lightdm", "x11vnc"]
}

/// A second NIC on a private segment with a static address (R-901). Both NICs are matched by MAC,
/// because a `network-config` replaces the image's default DHCP setup.
public struct SegmentNIC: Codable, Sendable, Hashable {
  /// MAC of the NAT NIC, which keeps DHCP.
  public var primaryMAC: String
  /// MAC of the segment NIC.
  public var mac: String
  /// The static IPv4 address, e.g. `10.1.0.10`.
  public var address: String
  public var prefixLength: Int

  public init(primaryMAC: String, mac: String, address: String, prefixLength: Int = 24) {
    self.primaryMAC = primaryMAC
    self.mac = mac
    self.address = address
    self.prefixLength = prefixLength
  }
}

/// A host directory shared into the guest, mounted by cloud-init `mounts` (R-404, R-603).
public struct GuestMount: Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable {
    /// QEMU `-virtfs` (9p over virtio).
    case ninep = "9p"
    /// Virtualization.framework `VZVirtioFileSystemDeviceConfiguration`.
    case virtiofs
  }

  /// The device tag, e.g. `share0`.
  public var tag: String
  public var guestPath: String
  public var kind: Kind
  public var readOnly: Bool

  public init(tag: String, guestPath: String, kind: Kind, readOnly: Bool = false) {
    self.tag = tag
    self.guestPath = guestPath
    self.kind = kind
    self.readOnly = readOnly
  }

  var options: String {
    let mode = readOnly ? "ro" : "rw"
    switch kind {
    case .ninep: return "trans=virtio,version=9p2000.L,\(mode),nofail"
    case .virtiofs: return "\(mode),nofail"
    }
  }
}

/// Everything a NoCloud seed says about a guest. Later items fill the optional parts.
public struct CloudInitConfig: Codable, Sendable, Hashable {
  /// cloud-init runs per-instance modules once per `instance-id`; use the VM's id.
  public var instanceID: String
  public var hostname: String
  /// The image's default login user (Appendix H), who receives the SSH key.
  public var user: String
  /// The VM's SSH public key, one `authorized_keys` line.
  public var sshPublicKey: String
  /// Extra packages; `qemu-guest-agent` is always installed.
  public var packages: [String]
  public var gui: GUIStack?
  public var segment: SegmentNIC?
  public var mounts: [GuestMount]
  public var console: ConsoleDevice
  /// MAC of the NAT NIC when the host finds the guest's address by MAC (VZ reads vmnet's
  /// `dhcpd_leases`): `network-config` then matches it and sets `dhcp-identifier: mac`, because
  /// systemd-networkd's default DUID client identifier hides the MAC from the lease file.
  public var dhcpIdentifierMAC: String?
  /// User-supplied `user-data`, merged after ours (cloud-config, shell script, boothook or
  /// include). Its cloud-config keys win; lists are appended.
  public var extraUserData: String?
  /// The request's `provision.runCommands` (R-1001), run as root in order after vmlab's own
  /// `runcmd` entries.
  public var runCommands: [String]

  public init(
    instanceID: String, hostname: String, user: String, sshPublicKey: String,
    packages: [String] = [], gui: GUIStack? = nil, segment: SegmentNIC? = nil,
    mounts: [GuestMount] = [], console: ConsoleDevice = .ttyAMA0,
    dhcpIdentifierMAC: String? = nil, extraUserData: String? = nil, runCommands: [String] = []
  ) {
    self.instanceID = instanceID
    self.hostname = hostname
    self.user = user
    self.sshPublicKey = sshPublicKey
    self.packages = packages
    self.gui = gui
    self.segment = segment
    self.mounts = mounts
    self.console = console
    self.dhcpIdentifierMAC = dhcpIdentifierMAC
    self.extraUserData = extraUserData
    self.runCommands = runCommands
  }

  /// `provision` applied: its packages, user-data and commands.
  public func provisioned(_ provision: ProvisionSpec?) -> CloudInitConfig {
    guard let provision else { return self }
    var config = self
    for package in provision.packages where !config.packages.contains(package) {
      config.packages.append(package)
    }
    if let userData = provision.userData, !userData.isEmpty { config.extraUserData = userData }
    config.runCommands += provision.runCommands
    return config
  }
}

/// Builds the NoCloud seed (`user-data`, `meta-data`, optional `network-config`) and the `cidata`
/// ISO both engines attach. YAML is emitted by hand (constraint C5: no YAML library).
public enum CloudInit {
  /// The merge policy of the user's part: their keys replace ours, lists are appended.
  public static let mergeType = "list(append)+dict(recurse_array)+str()"
  static let boundary = "==VMLAB-CLOUD-INIT-BOUNDARY=="

  /// Our `#cloud-config` document, before any user part.
  public static func cloudConfig(_ config: CloudInitConfig) -> String {
    var packages = ["qemu-guest-agent"]
    if config.gui != nil { packages += GUIStack.packages }
    for package in config.packages where !packages.contains(package) { packages.append(package) }

    var runcmd: [YAML] = [
      .list(["systemctl", "enable", "--now", "qemu-guest-agent"]),
      .list(["systemctl", "enable", "--now", "serial-getty@\(config.console.rawValue).service"]),
    ]
    var writeFiles: [YAML] = []
    if let gui = config.gui {
      writeFiles.append(
        .map([
          ("path", "/etc/lightdm/lightdm.conf.d/50-vmlab-autologin.conf"),
          ("permissions", "0644"),
          ("content", .string("[Seat:*]\nautologin-user=\(config.user)\nautologin-session=xfce\n")),
        ]))
      writeFiles.append(
        .map([
          ("path", "/etc/systemd/system/vmlab-vnc.service"),
          ("permissions", "0644"),
          ("content", .string(vncUnit(port: gui.vncPort))),
        ]))
      runcmd += [
        .list(["x11vnc", "-storepasswd", .string(gui.vncPassword), "/etc/x11vnc.pass"]),
        .list(["chmod", "0600", "/etc/x11vnc.pass"]),
        .list(["systemctl", "daemon-reload"]),
        .list(["systemctl", "set-default", "graphical.target"]),
        .list(["systemctl", "enable", "--now", "lightdm"]),
        .list(["systemctl", "enable", "--now", "vmlab-vnc.service"]),
      ]
    }

    var entries: [(String, YAML)] = [
      ("hostname", .string(config.hostname)),
      ("fqdn", .string(config.hostname)),
      ("manage_etc_hosts", true),
      ("ssh_pwauth", false),
      ("disable_root", true),
      (
        "users",
        .list([
          .map([
            ("name", .string(config.user)),
            ("groups", "sudo"),
            ("sudo", "ALL=(ALL) NOPASSWD:ALL"),
            ("shell", "/bin/bash"),
            ("lock_passwd", true),
            ("ssh_authorized_keys", .list([.string(config.sshPublicKey)])),
          ])
        ])
      ),
      ("package_update", true),
      ("packages", .list(packages.map(YAML.string))),
    ]
    if !config.mounts.isEmpty {
      entries.append(
        (
          "mounts",
          .list(
            config.mounts.map { mount in
              .list([
                .string(mount.tag), .string(mount.guestPath), .string(mount.kind.rawValue),
                .string(mount.options), "0", "0",
              ])
            })
        ))
    }
    for command in config.runCommands { runcmd.append(.list(["sh", "-c", .string(command)])) }
    if !writeFiles.isEmpty { entries.append(("write_files", .list(writeFiles))) }
    entries.append(("runcmd", .list(runcmd)))
    return "#cloud-config\n" + YAML.map(entries).render()
  }

  /// The `user-data` file: our cloud-config alone, or a MIME multipart with the user's part last.
  public static func userData(_ config: CloudInitConfig) throws -> String {
    let ours = cloudConfig(config)
    guard let extra = config.extraUserData, !extra.isEmpty else { return ours }
    let type = try contentType(of: extra)
    var parts = [
      "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
      "MIME-Version: 1.0",
      "",
      "--\(boundary)",
      "Content-Type: text/cloud-config; charset=\"utf-8\"",
      "Content-Disposition: attachment; filename=\"vmlab.cfg\"",
      "",
      ours,
      "--\(boundary)",
      "Content-Type: \(type); charset=\"utf-8\"",
      "Content-Disposition: attachment; filename=\"user-data\"",
    ]
    if type == "text/cloud-config" { parts.append("Merge-Type: \(mergeType)") }
    parts += ["", extra.hasSuffix("\n") ? String(extra.dropLast()) : extra, "--\(boundary)--", ""]
    return parts.joined(separator: "\n")
  }

  /// The `meta-data` file.
  public static func metaData(_ config: CloudInitConfig) -> String {
    YAML.map([
      ("instance-id", .string(config.instanceID)),
      ("local-hostname", .string(config.hostname)),
    ]).render()
  }

  /// The `network-config` (version 2) file, only when a segment NIC needs a static address or
  /// the NAT NIC must identify itself to DHCP by MAC.
  public static func networkConfig(_ config: CloudInitConfig) -> String? {
    guard let primary = config.dhcpIdentifierMAC ?? config.segment?.primaryMAC else { return nil }
    var nat: [(String, YAML)] = [
      ("match", .map([("macaddress", .string(primary.lowercased()))])),
      ("dhcp4", true),
    ]
    if config.dhcpIdentifierMAC != nil { nat.append(("dhcp-identifier", "mac")) }
    var ethernets: [(String, YAML)] = [("nat0", .map(nat))]
    if let segment = config.segment {
      ethernets.append(
        (
          "seg0",
          .map([
            ("match", .map([("macaddress", .string(segment.mac.lowercased()))])),
            ("dhcp4", false),
            ("addresses", .list([.string("\(segment.address)/\(segment.prefixLength)")])),
          ])
        ))
    }
    return YAML.map([("version", 2), ("ethernets", .map(ethernets))]).render()
  }

  /// Writes the seed files into `directory` and builds `iso` from them with `hdiutil makehybrid`.
  public static func makeSeed(
    _ config: CloudInitConfig, directory: URL, iso: URL,
    runner: any CommandRunning = ProcessRunner(), hdiutil: String = "/usr/bin/hdiutil"
  ) throws {
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(try userData(config).utf8).write(to: directory.appending(path: "user-data"))
    try Data(metaData(config).utf8).write(to: directory.appending(path: "meta-data"))
    let network = directory.appending(path: "network-config")
    if let text = networkConfig(config) {
      try Data(text.utf8).write(to: network)
    } else if files.fileExists(atPath: network.path) {
      try files.removeItem(at: network)
    }
    if files.fileExists(atPath: iso.path) { try files.removeItem(at: iso) }
    let arguments = [
      "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", iso.path,
      directory.path,
    ]
    guard let result = runner.run(hdiutil, arguments) else {
      throw VMLabError(
        code: .hostMissingTool, message: "Cannot run \(hdiutil) to build the cloud-init seed.",
        hint: "hdiutil ships with macOS; check that \(hdiutil) exists.",
        data: ["tool": .string("hdiutil")])
    }
    guard result.status == 0 else {
      throw VMLabError(
        code: .provisionFailed, message: "hdiutil makehybrid failed building the cloud-init seed.",
        hint: "See data.output for hdiutil's message.",
        data: ["status": .number(Double(result.status)), "output": .string(result.output)])
    }
  }

  static func contentType(of userData: String) throws -> String {
    let prefixes = [
      ("#cloud-config", "text/cloud-config"), ("#!", "text/x-shellscript"),
      ("#cloud-boothook", "text/cloud-boothook"), ("#include", "text/x-include-url"),
    ]
    if let match = prefixes.first(where: { userData.hasPrefix($0.0) }) { return match.1 }
    throw VMLabError.invalidRequest(
      field: "user_data",
      reason: "user-data must start with #cloud-config, #!, #cloud-boothook or #include",
      hint: "Begin the user-data with a cloud-init header line such as #cloud-config.")
  }

  static func vncUnit(port: Int) -> String {
    """
    [Unit]
    Description=vmlab VNC server for the desktop
    After=lightdm.service
    Requires=lightdm.service

    [Service]
    ExecStart=/usr/bin/x11vnc -display :0 -auth guess -forever -shared -rfbport \(port) -rfbauth /etc/x11vnc.pass
    Restart=always
    RestartSec=2

    [Install]
    WantedBy=graphical.target

    """
  }
}

/// A YAML node emitted in block style. Every string scalar is double-quoted with JSON-style escapes,
/// so no value can change type or break the document.
enum YAML: ExpressibleByStringInterpolation, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral
{
  case string(String)
  case bool(Bool)
  case int(Int)
  case list([YAML])
  case map([(String, YAML)])

  init(stringLiteral value: String) { self = .string(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
  init(integerLiteral value: Int) { self = .int(value) }

  func render() -> String {
    var lines: [String] = []
    emit(into: &lines, indent: 0)
    return lines.joined(separator: "\n") + "\n"
  }

  private var scalar: String? {
    switch self {
    case .string(let value): return Self.quote(value)
    case .bool(let value): return value ? "true" : "false"
    case .int(let value): return String(value)
    case .list(let items): return items.isEmpty ? "[]" : nil
    case .map(let entries): return entries.isEmpty ? "{}" : nil
    }
  }

  private func emit(into lines: inout [String], indent: Int) {
    let pad = String(repeating: " ", count: indent)
    switch self {
    case .list(let items) where !items.isEmpty:
      for item in items {
        if let scalar = item.scalar {
          lines.append(pad + "- " + scalar)
        } else {
          // Emit the nested node two deeper, then fold its first line onto the dash.
          var nested: [String] = []
          item.emit(into: &nested, indent: indent + 2)
          lines.append(pad + "- " + nested[0].dropFirst(indent + 2))
          lines += nested.dropFirst()
        }
      }
    case .map(let entries) where !entries.isEmpty:
      for (key, value) in entries {
        let name = Self.plainKey(key) ? key : Self.quote(key)
        if let scalar = value.scalar {
          lines.append(pad + name + ": " + scalar)
        } else {
          lines.append(pad + name + ":")
          value.emit(into: &lines, indent: indent + 2)
        }
      }
    default:
      lines.append(pad + (scalar ?? ""))
    }
  }

  private static func plainKey(_ key: String) -> Bool {
    guard let first = key.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first)
    else { return false }
    return key.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
    }
  }

  static func quote(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\t": out += "\\t"
      case "\r": out += "\\r"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
          || scalar.value == 0xFEFF || scalar.value == 0x2028 || scalar.value == 0x2029
        {
          out += String(format: "\\u%04X", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}
