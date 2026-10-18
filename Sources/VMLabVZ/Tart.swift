import Foundation
import VMLabCore

/// A Tart VM directory's `config.json` (Tart 2.x, `version: 1`): the fields vmlab reads to build
/// a `VZMacPlatformConfiguration` itself. `hardwareModel` and `ecid` are the base64 of
/// `VZMacHardwareModel.dataRepresentation` and `VZMacMachineIdentifier.dataRepresentation`.
public struct TartVMConfig: Codable, Sendable, Hashable {
  public struct Display: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
  }

  public var version: Int
  public var os: String
  public var arch: String
  public var cpuCountMin: Int
  public var cpuCount: Int
  public var memorySizeMin: UInt64
  public var memorySize: UInt64
  public var macAddress: String
  public var display: Display?
  public var diskFormat: String?
  public var hardwareModel: String?
  public var ecid: String?

  /// The config versions whose layout this build reads.
  public static let supportedVersions: ClosedRange<Int> = 1...1

  /// Reads `<directory>/config.json`; `engine_error` when it is missing, not Tart's layout, or not
  /// a macOS arm64 VM.
  public static func read(from directory: URL) throws(VMLabError) -> TartVMConfig {
    let url = directory.appending(path: "config.json")
    let config: TartVMConfig
    do {
      config = try JSONDecoder().decode(TartVMConfig.self, from: Data(contentsOf: url))
    } catch {
      throw layoutError(url, "\(error)")
    }
    guard supportedVersions.contains(config.version) else {
      throw layoutError(url, "config version \(config.version) is not one this build reads")
    }
    guard config.os == "darwin", config.arch == "arm64" else {
      throw layoutError(url, "a \(config.os)/\(config.arch) VM is not a macOS arm64 guest")
    }
    guard config.hardwareModel != nil, config.ecid != nil else {
      throw layoutError(url, "hardwareModel or ecid is missing")
    }
    guard MACAddress.normalize(config.macAddress) != nil else {
      throw layoutError(url, "macAddress \(config.macAddress) is not a MAC address")
    }
    return config
  }

  static func layoutError(_ url: URL, _ reason: String) -> VMLabError {
    VMLabError(
      code: .engineError, message: "Cannot read the Tart VM \(url.path): \(reason)",
      hint: "Pull the image again with this build's pinned Tart (2.x), then recreate the VM.",
      data: ["engine": .string("tart"), "raw": .string(reason)])
  }
}

/// A Tart clone backing one `vz-macos` guest: its Tart name and the directory that holds
/// `config.json`, `disk.img` and `nvram.bin`. vmlab runs the guest in its own runner from these
/// files; Tart only pulls and clones.
public struct TartVMFiles: Sendable, Hashable {
  public var directory: URL

  public init(directory: URL) { self.directory = directory }

  public var config: URL { directory.appending(path: "config.json") }
  public var disk: URL { directory.appending(path: "disk.img") }
  /// The Mac auxiliary storage (`VZMacAuxiliaryStorage`).
  public var nvram: URL { directory.appending(path: "nvram.bin") }
}

/// The `tart` command line, for what vmlab asks of it: pull (Core's `ImageStore`), clone,
/// grow a clone's disk and delete. Tart keeps its VMs under `TART_HOME` (default `~/.tart`) in `vms/<name>/`.
public struct Tart: Sendable {
  public static let installHint = "brew install cirruslabs/cli/tart"

  public var executable: String
  public var home: URL
  public var commands: any CommandRunning

  public init(executable: String, home: URL, commands: any CommandRunning = ProcessRunner()) {
    self.executable = executable
    self.home = home
    self.commands = commands
  }

  /// `TART_HOME`, or `~/.tart`.
  public static func defaultHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let home = environment["TART_HOME"], !home.isEmpty { return URL(filePath: home) }
    return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".tart")
  }

  /// The first executable `tart` on `searchPaths`; `host_missing_tool` when there is none.
  public static func locate(
    searchPaths: [String] = HostProbe.defaultSearchPaths(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    commands: any CommandRunning = ProcessRunner()
  ) throws(VMLabError) -> Tart {
    for directory in searchPaths {
      let path = URL(filePath: directory).appending(path: "tart").path
      if FileManager.default.isExecutableFile(atPath: path) {
        return Tart(
          executable: path, home: defaultHome(environment: environment), commands: commands)
      }
    }
    throw VMLabError(
      code: .hostMissingTool, message: "tart is not installed", hint: "Run: \(installHint)",
      data: ["tool": .string("tart"), "fix": .string(installHint)])
  }

  public func files(of name: String) -> TartVMFiles {
    TartVMFiles(directory: home.appending(path: "vms").appending(path: name))
  }

  /// `tart clone <source> <name>`: an APFS clone of a pulled image, with a fresh MAC address.
  public func clone(_ source: String, to name: String) throws(VMLabError) -> TartVMFiles {
    try run(["clone", source, name], what: "tart clone \(source) \(name)")
    return files(of: name)
  }

  /// `tart set <name> --disk-size <gigabytes>`: grows the clone's `disk.img` (Tart refuses to
  /// shrink). The guest's APFS container is not resized by this.
  public func setDiskSize(_ name: String, gigabytes: Int) throws(VMLabError) {
    try run(
      ["set", name, "--disk-size", String(gigabytes)],
      what: "tart set \(name) --disk-size \(gigabytes)")
  }

  /// `tart delete <name>`; a clone that is already gone is not an error.
  public func delete(_ name: String) throws(VMLabError) {
    guard FileManager.default.fileExists(atPath: files(of: name).directory.path) else { return }
    try run(["delete", name], what: "tart delete \(name)")
  }

  func run(_ arguments: [String], what: String) throws(VMLabError) {
    let output = commands.run(executable, arguments)
    guard let output, output.status == 0 else {
      throw VMLabError(
        code: .engineError, message: "\(what) failed",
        hint: "Check free disk space and `tart list`, then try again.",
        data: [
          "engine": .string("tart"),
          "raw": .string(
            output?.output.trimmingCharacters(in: .whitespacesAndNewlines)
              ?? "did not launch"),
        ])
    }
  }
}
