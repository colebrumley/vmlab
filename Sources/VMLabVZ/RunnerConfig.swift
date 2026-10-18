import Foundation
import VMLabCore

/// The files of one VZ guest's runner, all in the VM directory (Appendix F).
public struct VZRunnerPaths: Sendable, Hashable {
  public var vmDirectory: URL

  public init(vmDirectory: URL) {
    self.vmDirectory = vmDirectory
  }

  /// The control socket the runner listens on.
  public var controlSocket: URL { vmDirectory.appending(path: "control.sock") }
  /// The runner's pid, written when it starts and removed when it exits.
  public var pidFile: URL { vmDirectory.appending(path: "vz.pid") }
  /// The runner's stdout and stderr, appended to across runs.
  public var log: URL { vmDirectory.appending(path: "vz.log") }
  /// The guest's virtio console as a unix stream socket (R-602), read by `SerialChannel`.
  public var serialSocket: URL { vmDirectory.appending(path: "serial.sock") }
  /// The `VZRunnerConfig` the runner builds its machine from.
  public var config: URL { vmDirectory.appending(path: "vz-config.json") }

  /// The pid recorded in `vz.pid`, if any.
  public func recordedPID() -> Int32? {
    guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// The machine a runner builds, as plain data so the server writes it and the runner (the only
/// process that loads Virtualization.framework) reads it. `VZRunnerConfig.linux(record:...)` turns a
/// `VMRecord` into it (R-601); `decisions(limits:)` resolves it into `VZMachineDecisions`, the
/// device list the runner's `ConfigurationBuilder` materialises one to one.
public struct VZRunnerConfig: Codable, Sendable, Hashable {
  public struct Disk: Codable, Sendable, Hashable {
    /// Absolute path of a raw disk image (or the cloud-init ISO, which VZ attaches as raw bytes).
    public var path: String
    public var readOnly: Bool

    public init(path: String, readOnly: Bool = false) {
      self.path = path
      self.readOnly = readOnly
    }
  }

  /// A host directory shared over virtiofs (`VZVirtioFileSystemDeviceConfiguration` with a
  /// `VZSingleDirectoryShare`), mounted in the guest by cloud-init.
  public struct DirectoryShare: Codable, Sendable, Hashable {
    public var tag: String
    public var path: String
    public var readOnly: Bool

    public init(tag: String, path: String, readOnly: Bool = false) {
      self.tag = tag
      self.path = path
      self.readOnly = readOnly
    }
  }

  /// The virtiofs tag of the Rosetta share (`VZLinuxRosettaDirectoryShare`).
  public static let rosettaTag = "rosetta"

  public enum Network: Codable, Sendable, Hashable {
    /// `VZNATNetworkDeviceAttachment`; nil MAC means a random locally administered one.
    case nat(macAddress: String?)
  }

  public enum Boot: Codable, Sendable, Hashable {
    /// `VZEFIBootLoader` with the variable store at `variableStore`, created when absent.
    case efi(variableStore: String)
    /// `VZLinuxBootLoader` (R-604): an uncompressed arm64 `Image`, optional initrd, command line.
    case linuxKernel(kernel: String, initrd: String?, commandLine: String)
    /// `VZMacOSBootLoader` on a `VZMacPlatformConfiguration` (R-605): the base64
    /// `dataRepresentation`s of the hardware model and machine identifier, and the auxiliary
    /// storage (`nvram.bin`) path, all from the guest's Tart clone.
    case macOS(hardwareModel: String, machineIdentifier: String, auxiliaryStorage: String)
  }

  /// The guest display (`VZVirtioGraphicsDeviceConfiguration`), present only when `gui` was
  /// granted.
  public struct Graphics: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    /// Set for a macOS guest's `VZMacGraphicsDisplayConfiguration`; nil for virtio graphics.
    public var pixelsPerInch: Int?

    public init(width: Int = 1280, height: Int = 800, pixelsPerInch: Int? = nil) {
      self.width = width
      self.height = height
      self.pixelsPerInch = pixelsPerInch
    }
  }

  public var cpus: Int
  public var memoryBytes: UInt64
  public var boot: Boot
  /// Boot disk first, then the cloud-init seed.
  public var disks: [Disk]
  public var network: [Network]
  /// Where the runner appends the guest's virtio console output, which it reads from the console
  /// pipe; nil attaches no console.
  public var consoleLog: String?
  /// Where the runner serves the same console as a unix stream socket (`SerialBridge`, R-602);
  /// nil serves none. Only meaningful with `consoleLog`.
  public var serialSocket: String?
  public var memoryBalloon: Bool
  public var graphics: Graphics?
  /// Host directories shared over virtiofs (R-603).
  public var directoryShares: [DirectoryShare]
  /// Whether to share Rosetta for Linux with the guest under `rosettaTag` (R-603).
  public var rosetta: Bool
  /// Where the `VZGenericMachineIdentifier` is kept (created on first use), so every machine
  /// built for the VM is the same one: a saved state restores only into its own machine (R-608).
  public var machineIdentifier: String?
  /// `VZGenericPlatformConfiguration.isNestedVirtualizationEnabled` (R-609): the guest can run
  /// KVM. Only on hosts where the framework supports it (M3 or newer, macOS 15).
  public var nestedVirtualization: Bool

  public init(
    cpus: Int, memoryBytes: UInt64, boot: Boot, disks: [Disk],
    network: [Network] = [.nat(macAddress: nil)], consoleLog: String? = nil,
    serialSocket: String? = nil, memoryBalloon: Bool = true, graphics: Graphics? = nil,
    directoryShares: [DirectoryShare] = [], rosetta: Bool = false,
    machineIdentifier: String? = nil, nestedVirtualization: Bool = false
  ) {
    self.cpus = cpus
    self.memoryBytes = memoryBytes
    self.boot = boot
    self.disks = disks
    self.network = network
    self.consoleLog = consoleLog
    self.serialSocket = serialSocket
    self.memoryBalloon = memoryBalloon
    self.graphics = graphics
    self.directoryShares = directoryShares
    self.rosetta = rosetta
    self.machineIdentifier = machineIdentifier
    self.nestedVirtualization = nestedVirtualization
  }

  enum CodingKeys: String, CodingKey {
    case cpus, memoryBytes, boot, disks, network, consoleLog, serialSocket, memoryBalloon
    case graphics, directoryShares, rosetta, machineIdentifier, nestedVirtualization
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    cpus = try c.decode(Int.self, forKey: .cpus)
    memoryBytes = try c.decode(UInt64.self, forKey: .memoryBytes)
    boot = try c.decode(Boot.self, forKey: .boot)
    disks = try c.decode([Disk].self, forKey: .disks)
    network = try c.decode([Network].self, forKey: .network)
    consoleLog = try c.decodeIfPresent(String.self, forKey: .consoleLog)
    serialSocket = try c.decodeIfPresent(String.self, forKey: .serialSocket)
    memoryBalloon = try c.decode(Bool.self, forKey: .memoryBalloon)
    graphics = try c.decodeIfPresent(Graphics.self, forKey: .graphics)
    directoryShares = try c.decodeIfPresent([DirectoryShare].self, forKey: .directoryShares) ?? []
    rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
    machineIdentifier = try c.decodeIfPresent(String.self, forKey: .machineIdentifier)
    nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? false
  }

  /// The guest command line for `.kernel` boot without one: the root on the first virtio disk and
  /// the console on the virtio console.
  public static let defaultCommandLine = "console=hvc0 root=/dev/vda1 rw"

  /// The complete Linux machine for `record` in `vmDirectory`: its resources (Appendix G defaults
  /// for the rest), `.disk` boot (default) through EFI with `<vm>/efi-vars.bin` or `.kernel` boot
  /// through `VZLinuxBootLoader`, `<vm>/disk.raw`, `<vm>/seed.iso` read-only when `seed`, one NAT
  /// NIC with `stableMAC(for:)` unless the network is `none`, the console appended to
  /// `<vm>/console.log` and served on `<vm>/serial.sock`, the record's share (`SharedDirSpec.of`) over virtiofs
  /// as `share0`, Rosetta when the plan asked for `rosetta`, the balloon, and graphics only when `gui` was granted.
  public static func linux(
    record: VMRecord, vmDirectory: URL, boot: BootSpec? = nil, seed: Bool = true
  ) throws(VMLabError) -> VZRunnerConfig {
    let resources = ResourceLimits.resolve(record.resources, for: .linux)
    let loader: Boot
    switch boot?.mode ?? .disk {
    case .disk:
      loader = .efi(variableStore: vmDirectory.appending(path: "efi-vars.bin").path)
    case .kernel:
      guard let kernel = boot?.kernel else {
        throw VMLabError.invalidRequest(
          field: "boot.kernel", reason: "kernel boot needs a kernel",
          hint: "Give boot.kernel the path of an uncompressed arm64 Image.")
      }
      loader = .linuxKernel(
        kernel: kernel, initrd: boot?.initrd,
        commandLine: boot?.cmdline ?? defaultCommandLine)
    case .firmware, .binary:
      throw VMLabError.invalidRequest(
        field: "boot.mode",
        reason: "Virtualization.framework boots only Apple EFI or a Linux kernel",
        hint: "Use boot.mode disk or kernel, or require custom_firmware to get a QEMU profile.")
    }
    var disks = [Disk(path: vmDirectory.appending(path: "disk.raw").path)]
    if seed {
      disks.append(Disk(path: vmDirectory.appending(path: "seed.iso").path, readOnly: true))
    }
    return VZRunnerConfig(
      cpus: resources.cpus ?? 2,
      memoryBytes: UInt64(resources.memoryGB ?? 4) << 30,
      boot: loader,
      disks: disks,
      network: record.network.mode == .disabled
        ? [] : [.nat(macAddress: stableMAC(for: record.id))],
      consoleLog: vmDirectory.appending(path: "console.log").path,
      serialSocket: vmDirectory.appending(path: "serial.sock").path,
      memoryBalloon: true,
      graphics: record.features.contains(.gui) ? Graphics() : nil,
      directoryShares: SharedDirSpec.of(record).map {
        [
          DirectoryShare(
            tag: SharedDirSpec.tag, path: $0.hostDirectory(vmDirectory: vmDirectory).path)
        ]
      } ?? [],
      rosetta: wantsRosetta(record),
      machineIdentifier: vmDirectory.appending(path: "machine-id.bin").path,
      nestedVirtualization: record.features.contains(.nestedVirt)
        && (record.plan?.requested.contains(.nestedVirt) ?? false))
  }

  /// Whether the guest gets the Rosetta share: only when the request asked for `rosetta`
  /// (required or preferred), not merely because the profile offers it.
  public static func wantsRosetta(_ record: VMRecord) -> Bool {
    record.features.contains(.rosetta) && (record.plan?.requested.contains(.rosetta) ?? false)
  }

  /// A locally administered unicast MAC derived from the VM's id, so the guest keeps its NIC (and
  /// its DHCP lease) across restarts without storing anything.
  public static func stableMAC(for id: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
    for byte in id.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x100_0000_01b3
    }
    var octets = (0..<6).map { UInt8(truncatingIfNeeded: hash >> (8 * UInt64($0))) }
    octets[0] = (octets[0] & 0xFC) | 0x02
    return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
  }

  /// Writes the config as JSON at `url`, replacing it atomically.
  public func write(to url: URL) throws(VMLabError) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(self).write(to: url, options: .atomic)
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot write \(url.path): \(error)",
        hint: "Check that the VM directory is writable.", data: ["file": .string(url.path)])
    }
  }

  public static func read(from url: URL) throws(VMLabError) -> VZRunnerConfig {
    do {
      return try JSONDecoder().decode(VZRunnerConfig.self, from: Data(contentsOf: url))
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot read the VZ configuration \(url.path): \(error)",
        hint: "Recreate the VM; its runner configuration is missing or corrupt.",
        data: ["file": .string(url.path)])
    }
  }
}
