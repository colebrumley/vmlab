import Foundation
import VMLabCore

/// Virtualization.framework's bounds on CPUs and memory. The runner passes the framework's own
/// `VZVirtualMachineConfiguration` limits; tests pass fixed numbers.
public struct VZMachineLimits: Sendable, Hashable {
  public var minCPUs: Int
  public var maxCPUs: Int
  public var minMemoryBytes: UInt64
  public var maxMemoryBytes: UInt64

  public init(minCPUs: Int, maxCPUs: Int, minMemoryBytes: UInt64, maxMemoryBytes: UInt64) {
    self.minCPUs = minCPUs
    self.maxCPUs = maxCPUs
    self.minMemoryBytes = minMemoryBytes
    self.maxMemoryBytes = maxMemoryBytes
  }
}

/// Every decision the runner's `ConfigurationBuilder` makes, as plain data: one entry per device
/// it creates, in the order it creates them. The builder switches over this and nothing else, so a
/// snapshot of it is a snapshot of the `VZVirtualMachineConfiguration`.
public struct VZMachineDecisions: Codable, Sendable, Hashable {
  public enum BootLoader: Codable, Sendable, Hashable {
    /// `VZEFIBootLoader` with a `VZEFIVariableStore` at the path (created when absent).
    case efi(variableStore: String)
    /// `VZLinuxBootLoader`.
    case linux(kernel: String, initrd: String?, commandLine: String)
    /// `VZMacOSBootLoader`; the platform is then a `VZMacPlatformConfiguration` built from these
    /// (base64 `dataRepresentation`s and the auxiliary storage path).
    case macOS(hardwareModel: String, machineIdentifier: String, auxiliaryStorage: String)
  }

  /// A `VZVirtioBlockDeviceConfiguration` over a `VZDiskImageStorageDeviceAttachment`.
  public struct BlockDevice: Codable, Sendable, Hashable {
    public var path: String
    public var readOnly: Bool

    public init(path: String, readOnly: Bool) {
      self.path = path
      self.readOnly = readOnly
    }
  }

  /// A `VZVirtioNetworkDeviceConfiguration` with a `VZNATNetworkDeviceAttachment`; `mac` is nil
  /// for a random locally administered address.
  public struct NATDevice: Codable, Sendable, Hashable {
    public var mac: String?

    public init(mac: String?) { self.mac = mac }
  }

  /// A `VZVirtioNetworkDeviceConfiguration` on a `VZFileHandleNetworkDeviceAttachment` over a
  /// datagram `socketpair`; the runner sends the other end to the switch at `attachSocket`.
  public struct SegmentDevice: Codable, Sendable, Hashable {
    public var mac: String
    public var attachSocket: String

    public init(mac: String, attachSocket: String) {
      self.mac = mac
      self.attachSocket = attachSocket
    }
  }

  /// A `VZVirtioConsoleDeviceSerialPortConfiguration` on a `VZFileHandleSerialPortAttachment`
  /// over two pipes the runner owns; it appends guest output to `log` and bridges both pipes to
  /// the unix socket `socket` when set (`SerialBridge`, R-602).
  public struct Console: Codable, Sendable, Hashable {
    public var log: String
    public var socket: String?

    public init(log: String, socket: String? = nil) {
      self.log = log
      self.socket = socket
    }
  }

  /// A `VZVirtioGraphicsDeviceConfiguration` with one scanout (a `VZMacGraphicsDeviceConfiguration`
  /// with one display of `pixelsPerInch` for a macOS guest), plus a USB keyboard and a USB
  /// absolute pointing device so the desktop takes input.
  public struct Graphics: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var pixelsPerInch: Int?

    public init(width: Int, height: Int, pixelsPerInch: Int? = nil) {
      self.width = width
      self.height = height
      self.pixelsPerInch = pixelsPerInch
    }
  }

  /// A `VZVirtioFileSystemDeviceConfiguration`: a `VZSingleDirectoryShare` of `path`, or with
  /// `rosetta` a `VZLinuxRosettaDirectoryShare` (and no path).
  public struct FileSystemDevice: Codable, Sendable, Hashable {
    public var tag: String
    public var path: String?
    public var readOnly: Bool
    public var rosetta: Bool

    public init(tag: String, path: String?, readOnly: Bool, rosetta: Bool = false) {
      self.tag = tag
      self.path = path
      self.readOnly = readOnly
      self.rosetta = rosetta
    }
  }

  public var cpus: Int
  /// Rounded down to a whole MiB, then clamped.
  public var memoryBytes: UInt64
  /// `generic` (`VZGenericPlatformConfiguration`) for Linux, `mac` for `.macOS` boot.
  public var platform: String
  /// The file holding the platform's `VZGenericMachineIdentifier`, created when absent; nil is a
  /// fresh identifier per machine.
  public var machineIdentifier: String?
  /// `isNestedVirtualizationEnabled` on the generic platform (R-609).
  public var nestedVirtualization: Bool
  public var bootLoader: BootLoader
  public var storage: [BlockDevice]
  public var network: [NATDevice]
  /// The segment NIC (R-901), after the NAT NIC; absent off a segment.
  public var segment: SegmentDevice?
  public var console: Console?
  /// `VZVirtioEntropyDeviceConfiguration` (virtio-rng); always present.
  public var entropy: Bool
  /// `VZVirtioTraditionalMemoryBalloonDeviceConfiguration`.
  public var memoryBalloon: Bool
  public var graphics: Graphics?
  /// virtiofs devices: the shares in order, then Rosetta.
  public var fileSystems: [FileSystemDevice]
}

extension VZRunnerConfig {
  /// Resolves the config against the framework's limits; `invalid_request` for a MAC that is not
  /// six colon-separated hex octets.
  public func decisions(limits: VZMachineLimits) throws(VMLabError) -> VZMachineDecisions {
    let mib: UInt64 = 1 << 20
    let loader: VZMachineDecisions.BootLoader =
      switch boot {
      case .efi(let store): .efi(variableStore: store)
      case .linuxKernel(let kernel, let initrd, let line):
        .linux(kernel: kernel, initrd: initrd, commandLine: line)
      case .macOS(let model, let identifier, let auxiliary):
        .macOS(hardwareModel: model, machineIdentifier: identifier, auxiliaryStorage: auxiliary)
      }
    var platform = "generic"
    if case .macOS = loader { platform = "mac" }
    func normalized(_ mac: String) throws(VMLabError) -> String {
      guard let normalized = MACAddress.normalize(mac) else {
        throw VMLabError.invalidRequest(
          field: "network.macAddress", reason: "\(mac) is not a MAC address",
          hint: "Use six colon-separated hex octets.")
      }
      return normalized
    }
    var nics: [VZMachineDecisions.NATDevice] = []
    var segment: VZMachineDecisions.SegmentDevice?
    for nic in network {
      switch nic {
      case .nat(let mac):
        nics.append(VZMachineDecisions.NATDevice(mac: try mac.map(normalized)))
      case .segment(let mac, let socket):
        segment = VZMachineDecisions.SegmentDevice(mac: try normalized(mac), attachSocket: socket)
      }
    }
    return VZMachineDecisions(
      cpus: min(max(cpus, limits.minCPUs), limits.maxCPUs),
      memoryBytes: min(max(memoryBytes / mib * mib, limits.minMemoryBytes), limits.maxMemoryBytes),
      platform: platform,
      machineIdentifier: machineIdentifier,
      nestedVirtualization: nestedVirtualization,
      bootLoader: loader,
      storage: disks.map { .init(path: $0.path, readOnly: $0.readOnly) },
      network: nics,
      segment: segment,
      console: consoleLog.map { .init(log: $0, socket: serialSocket) },
      entropy: true,
      memoryBalloon: memoryBalloon,
      graphics: graphics.map {
        .init(width: $0.width, height: $0.height, pixelsPerInch: $0.pixelsPerInch)
      },
      fileSystems: directoryShares.map {
        .init(tag: $0.tag, path: $0.path, readOnly: $0.readOnly)
      }
        + (rosetta
          ? [.init(tag: VZRunnerConfig.rosettaTag, path: nil, readOnly: true, rosetta: true)] : []))
  }
}

/// MAC address text in the two spellings vmlab meets.
public enum MACAddress {
  /// Lowercase, two digits per octet: `2:A:3b:4c:5d:6e` → `02:0a:3b:4c:5d:6e`. macOS's
  /// `dhcpd_leases` drops leading zeros; nil unless there are six hex octets of one or two digits.
  public static func normalize(_ text: String) -> String? {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6 else { return nil }
    var octets: [String] = []
    for part in parts {
      guard (1...2).contains(part.count), let value = UInt8(part, radix: 16) else { return nil }
      octets.append(String(format: "%02x", value))
    }
    return octets.joined(separator: ":")
  }
}
