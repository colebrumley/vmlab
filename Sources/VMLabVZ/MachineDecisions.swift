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

  /// A `VZVirtioGraphicsDeviceConfiguration` with one scanout, plus a USB keyboard and a USB
  /// absolute pointing device so the desktop takes input.
  public struct Graphics: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }
  }

  public var cpus: Int
  /// Rounded down to a whole MiB, then clamped.
  public var memoryBytes: UInt64
  /// Always `VZGenericPlatformConfiguration`.
  public var platform: String
  public var bootLoader: BootLoader
  public var storage: [BlockDevice]
  public var network: [NATDevice]
  public var console: Console?
  /// `VZVirtioEntropyDeviceConfiguration` (virtio-rng); always present.
  public var entropy: Bool
  /// `VZVirtioTraditionalMemoryBalloonDeviceConfiguration`.
  public var memoryBalloon: Bool
  public var graphics: Graphics?
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
      }
    let nics = try network.map { network throws(VMLabError) in
      switch network {
      case .nat(let mac):
        guard let mac else { return VZMachineDecisions.NATDevice(mac: nil) }
        guard let normalized = MACAddress.normalize(mac) else {
          throw VMLabError.invalidRequest(
            field: "network.macAddress", reason: "\(mac) is not a MAC address",
            hint: "Use six colon-separated hex octets.")
        }
        return VZMachineDecisions.NATDevice(mac: normalized)
      }
    }
    return VZMachineDecisions(
      cpus: min(max(cpus, limits.minCPUs), limits.maxCPUs),
      memoryBytes: min(max(memoryBytes / mib * mib, limits.minMemoryBytes), limits.maxMemoryBytes),
      platform: "generic",
      bootLoader: loader,
      storage: disks.map { .init(path: $0.path, readOnly: $0.readOnly) },
      network: nics,
      console: consoleLog.map { .init(log: $0, socket: serialSocket) },
      entropy: true,
      memoryBalloon: memoryBalloon,
      graphics: graphics.map { .init(width: $0.width, height: $0.height) })
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
