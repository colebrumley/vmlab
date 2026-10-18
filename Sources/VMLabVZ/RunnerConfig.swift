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
  /// The `VZRunnerConfig` the runner builds its machine from.
  public var config: URL { vmDirectory.appending(path: "vz-config.json") }

  /// The pid recorded in `vz.pid`, if any.
  public func recordedPID() -> Int32? {
    guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// The machine a runner builds, as plain data so the server writes it and the runner (the only
/// process that loads Virtualization.framework) reads it. R-601 owns turning a `VMRecord` into the
/// complete configuration; this is the subset R-600 needs to boot an EFI Linux disk image.
public struct VZRunnerConfig: Codable, Sendable, Hashable {
  public struct Disk: Codable, Sendable, Hashable {
    /// Absolute path of a raw disk image.
    public var path: String
    public var readOnly: Bool

    public init(path: String, readOnly: Bool = false) {
      self.path = path
      self.readOnly = readOnly
    }
  }

  public enum Network: Codable, Sendable, Hashable {
    /// `VZNATNetworkDeviceAttachment`; nil MAC means a random locally administered one.
    case nat(macAddress: String?)
  }

  public var cpus: Int
  public var memoryBytes: UInt64
  /// Path of the EFI variable store; created when absent.
  public var efiVariableStore: String
  /// Boot disk first.
  public var disks: [Disk]
  public var network: [Network]
  /// Where the guest's virtio console output is appended; nil attaches no console. R-602 replaces
  /// this with the serial socket bridge.
  public var consoleLog: String?

  public init(
    cpus: Int, memoryBytes: UInt64, efiVariableStore: String, disks: [Disk],
    network: [Network] = [.nat(macAddress: nil)], consoleLog: String? = nil
  ) {
    self.cpus = cpus
    self.memoryBytes = memoryBytes
    self.efiVariableStore = efiVariableStore
    self.disks = disks
    self.network = network
    self.consoleLog = consoleLog
  }

  /// The minimal EFI Linux machine for `record`: its resources (Appendix G defaults for the rest),
  /// `<vm>/disk.raw` as the boot disk, `<vm>/efi-vars.bin`, one NAT NIC and the console appended to
  /// `<vm>/console.log`.
  public static func linuxEFI(record: VMRecord, vmDirectory: URL) -> VZRunnerConfig {
    let resources = ResourceLimits.resolve(record.resources, for: .linux)
    return VZRunnerConfig(
      cpus: resources.cpus ?? 2,
      memoryBytes: UInt64(resources.memoryGB ?? 4) << 30,
      efiVariableStore: vmDirectory.appending(path: "efi-vars.bin").path,
      disks: [Disk(path: vmDirectory.appending(path: "disk.raw").path)],
      network: [.nat(macAddress: nil)],
      consoleLog: vmDirectory.appending(path: "console.log").path)
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
