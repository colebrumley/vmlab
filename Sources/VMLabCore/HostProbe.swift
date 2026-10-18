import Foundation

/// The exit status and combined stdout and stderr of a host command.
public struct CommandOutput: Sendable, Equatable {
  public var status: Int32
  public var output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

/// Runs a host command. Tests substitute recorded output; `ProcessRunner` runs it for real.
public protocol CommandRunning: Sendable {
  /// Runs `executable` with `arguments`; nil when it cannot be launched.
  func run(_ executable: String, _ arguments: [String]) -> CommandOutput?
}

/// Runs host commands with `Process` and an argument array (never a shell).
public struct ProcessRunner: CommandRunning {
  public init() {}

  public func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandOutput(
      status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
  }
}

/// Gathers the fast host facts (Appendix E) at every server start and merges in the persisted slow
/// probes from `host-facts.json`. Every input is injectable so tests run on recorded output.
public struct HostProbe: Sendable {
  public static let rosettaRuntimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

  public var home: URL
  public var runner: any CommandRunning
  /// The `vmlab-vz` binary whose entitlement is checked; nil when it is not built.
  public var runnerPath: String?
  /// Directories searched for `qemu-system-aarch64` and `tart`, in order.
  public var searchPaths: [String]
  public var fileExists: @Sendable (String) -> Bool
  public var isRoot: @Sendable () -> Bool
  /// Running guests, (macOS, all). The VM store (R-104) supplies this; zero until then.
  public var runningGuests: @Sendable () -> (macOS: Int, total: Int)

  public init(
    home: URL,
    runner: any CommandRunning = ProcessRunner(),
    runnerPath: String? = HostProbe.defaultRunnerPath(),
    searchPaths: [String] = HostProbe.defaultSearchPaths(),
    fileExists: @escaping @Sendable (String) -> Bool = {
      FileManager.default.fileExists(atPath: $0)
    },
    isRoot: @escaping @Sendable () -> Bool = { geteuid() == 0 },
    runningGuests: @escaping @Sendable () -> (macOS: Int, total: Int) = { (0, 0) }
  ) {
    self.home = home
    self.runner = runner
    self.runnerPath = runnerPath
    self.searchPaths = searchPaths
    self.fileExists = fileExists
    self.isRoot = isRoot
    self.runningGuests = runningGuests
  }

  /// `vmlab-vz` next to the running executable.
  public static func defaultRunnerPath() -> String? {
    Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "vmlab-vz").path
  }

  /// Homebrew's prefixes first, then `PATH`.
  public static func defaultSearchPaths(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    var paths = ["/opt/homebrew/bin", "/usr/local/bin"]
    for entry in (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    where !entry.isEmpty && !paths.contains(entry) {
      paths.append(entry)
    }
    return paths
  }

  // MARK: Gathering

  /// Every fast fact, plus the slow probes still valid for this OS and QEMU version.
  public func gather() -> HostFacts {
    let osVersion = Self.parseSwVers(run("/usr/bin/sw_vers") ?? "") ?? "0"
    let sysctl = Self.parseSysctl(
      run("/usr/sbin/sysctl", ["machdep.cpu.brand_string", "hw.memsize"]) ?? "")
    let chip = Self.parseChip(brand: sysctl["machdep.cpu.brand_string"] ?? "")
    let memoryBytes = Double(sysctl["hw.memsize"] ?? "") ?? 0
    let freeMemoryBytes = Double(Self.parseVMStatAvailableBytes(run("/usr/bin/vm_stat") ?? "") ?? 0)
    let qemu = probeQEMU()
    let guests = runningGuests()
    let stored = (try? SlowProbes.load(from: SlowProbes.url(home: home))) ?? SlowProbes()
    return HostFacts(
      osVersion: osVersion,
      chip: chip,
      memoryGB: memoryBytes / Self.gib,
      freeMemoryGB: freeMemoryBytes / Self.gib,
      freeDiskGB: Double(freeDiskBytes()) / Self.gib,
      isRoot: isRoot(),
      qemu: qemu,
      tart: probeTart(),
      rosettaInstalled: fileExists(Self.rosettaRuntimePath),
      nestedSupported: Self.nestedSupported(chip: chip, osVersion: osVersion),
      runnerSigned: runnerSigned(),
      runningMacOSGuests: guests.macOS,
      runningGuests: guests.total,
      imagesBytes: imagesBytes(),
      probes: stored.invalidated(osVersion: osVersion, qemuVersion: qemu.version)
    )
  }

  private static let gib = 1_073_741_824.0

  private func run(_ executable: String, _ arguments: [String] = []) -> String? {
    guard let result = runner.run(executable, arguments), result.status == 0 else { return nil }
    return result.output
  }

  private func find(_ tool: String) -> String? {
    searchPaths.lazy.map { URL(filePath: $0).appending(path: tool).path }.first(where: fileExists)
  }

  private func probeQEMU() -> HostFacts.QEMU {
    guard let path = find("qemu-system-aarch64") else { return .absent }
    return HostFacts.QEMU(
      present: true,
      version: run(path, ["--version"]).flatMap(Self.parseQEMUVersion),
      path: path,
      accelerators: Self.parseQEMUAccelerators(run(path, ["-accel", "help"]) ?? ""))
  }

  private func probeTart() -> HostFacts.Tart {
    guard let path = find("tart") else { return .absent }
    return HostFacts.Tart(
      present: true, version: run(path, ["--version"]).flatMap(Self.parseTartVersion))
  }

  private func runnerSigned() -> Bool {
    guard let runnerPath, fileExists(runnerPath),
      let result = runner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", runnerPath])
    else { return false }
    return CodeSignature.hasVirtualizationEntitlement(codesignOutput: result.output)
  }

  private func freeDiskBytes() -> Int64 {
    var url = home
    while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
      url = url.deletingLastPathComponent()
    }
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }

  private func imagesBytes() -> Int64 {
    let images = home.appending(path: "images")
    guard
      let enumerator = FileManager.default.enumerator(
        at: images, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
    }
    return total
  }

  // MARK: Parsers (fixture-tested)

  /// `ProductVersion` from `sw_vers` output.
  public static func parseSwVers(_ output: String) -> String? {
    keyValues(output, separator: ":")["ProductVersion"]
  }

  /// `key: value` lines from `sysctl name...` output.
  public static func parseSysctl(_ output: String) -> [String: String] {
    keyValues(output, separator: ":")
  }

  /// The chip from `machdep.cpu.brand_string`: `Apple M1 Max` is generation 1.
  public static func parseChip(brand: String) -> HostFacts.Chip {
    let model = brand.trimmingCharacters(in: .whitespaces)
    let generation = model.split(separator: " ").lazy.compactMap { word -> Int? in
      guard word.first == "M" else { return nil }
      return Int(word.dropFirst())
    }.first
    return HostFacts.Chip(model: model, generation: generation)
  }

  /// The version number from `qemu-system-aarch64 --version` (`QEMU emulator version 11.1.2`).
  public static func parseQEMUVersion(_ output: String) -> String? {
    guard let line = output.split(separator: "\n").first(where: { $0.contains("version") }),
      let range = line.range(of: "version ")
    else { return nil }
    return line[range.upperBound...].split(separator: " ").first.map(String.init)
  }

  /// Accelerator names from `qemu-system-aarch64 -accel help`.
  public static func parseQEMUAccelerators(_ output: String) -> [String] {
    output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.contains(" ") && !$0.hasSuffix(":") }
  }

  /// The version from `tart --version` (a bare version number, perhaps with a trailing note).
  public static func parseTartVersion(_ output: String) -> String? {
    output.split(whereSeparator: \.isWhitespace).first { $0.first?.isNumber == true }.map(
      String.init)
  }

  /// Bytes the kernel can hand out without paging: free, inactive and speculative pages.
  public static func parseVMStatAvailableBytes(_ output: String) -> Int64? {
    let lines = output.split(separator: "\n")
    guard let header = lines.first, let sizeRange = header.range(of: "page size of "),
      let pageSize = Int64(header[sizeRange.upperBound...].prefix { $0.isNumber })
    else { return nil }
    let values = keyValues(output, separator: ":")
    let pages = ["Pages free", "Pages inactive", "Pages speculative"].compactMap { key in
      values[key].flatMap { Int64($0.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
    }
    guard !pages.isEmpty else { return nil }
    return pages.reduce(0, +) * pageSize
  }

  /// Nested virtualization needs an M3 or newer and macOS 15 or newer. The runner's
  /// `VZGenericPlatformConfiguration.isNestedVirtualizationSupported` replaces this inference
  /// once the VZ backend exists.
  public static func nestedSupported(chip: HostFacts.Chip, osVersion: String) -> Bool {
    let major = Int(osVersion.split(separator: ".").first ?? "") ?? 0
    return (chip.generation ?? 0) >= 3 && major >= 15
  }

  private static func keyValues(_ output: String, separator: Character) -> [String: String] {
    var result: [String: String] = [:]
    for line in output.split(separator: "\n") {
      guard let index = line.firstIndex(of: separator) else { continue }
      let key = line[..<index].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
      if !key.isEmpty { result[key] = value }
    }
    return result
  }
}
