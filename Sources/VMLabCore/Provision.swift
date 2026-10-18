import Foundation

/// The request's `provision` (R-1001): what first boot installs and runs beyond vmlab's own
/// setup. On Linux, `packages` and `userData` go into the cloud-init seed (the user-data merged
/// last, so its keys win) and `runCommands` run in order after cloud-init's own modules; on macOS
/// only `runCommands` apply, run over SSH once the guest answers.
public struct ProvisionSpec: Codable, Sendable, Hashable {
  /// Distribution packages to install (`jq`, `build-essential`, `nginx=1.26*`).
  public var packages: [String]
  /// cloud-init user-data (`#cloud-config`, `#!` script, `#cloud-boothook` or `#include`).
  public var userData: String?
  /// Shell commands run in order as root (Linux) or the login user (macOS); the first that exits
  /// non-zero stops the rest.
  public var runCommands: [String]

  public init(packages: [String] = [], userData: String? = nil, runCommands: [String] = []) {
    self.packages = packages
    self.userData = userData
    self.runCommands = runCommands
  }

  enum CodingKeys: String, CodingKey { case packages, userData, runCommands }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    packages = try c.decodeIfPresent([String].self, forKey: .packages) ?? []
    userData = try c.decodeIfPresent(String.self, forKey: .userData)
    runCommands = try c.decodeIfPresent([String].self, forKey: .runCommands) ?? []
  }

  /// True when nothing is asked for.
  public var isEmpty: Bool {
    packages.isEmpty && (userData ?? "").isEmpty && runCommands.isEmpty
  }

  /// A package name, optionally with an apt version (`=`) or architecture (`:`) qualifier and
  /// a glob in the version: letters, digits and `.+-_:=~*`, starting with a letter or digit.
  public static func isValidPackage(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
      name.unicodeScalars.allSatisfy({ $0.isASCII })
    else { return false }
    return name.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || ".+-_:=~*".unicodeScalars.contains($0)
    }
  }

  /// `invalid_request` for a malformed package, a user-data without a cloud-init header, an empty
  /// command, or anything but `runCommands` on a macOS guest.
  func validate(guest: GuestSpec) throws(VMLabError) {
    for (index, package) in packages.enumerated() where !Self.isValidPackage(package) {
      throw .invalidRequest(
        field: "provision.packages[\(index)]", reason: "\"\(package)\" is not a package name",
        hint: "Give package names as the guest's package manager knows them, such as jq.")
    }
    for (index, command) in runCommands.enumerated()
    where command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw .invalidRequest(
        field: "provision.runCommands[\(index)]", reason: "empty command",
        hint: "Drop the empty entry or give the shell command to run.")
    }
    if guest.os == .macos {
      if !packages.isEmpty {
        throw .invalidRequest(
          field: "provision.packages",
          reason: "a macOS guest has no cloud-init to install packages",
          hint: "Install them with provision.runCommands, such as \"brew install jq\".")
      }
      if let userData, !userData.isEmpty {
        throw .invalidRequest(
          field: "provision.userData", reason: "a macOS guest has no cloud-init to read user-data",
          hint: "Use provision.runCommands for a macOS guest.")
      }
    }
    if let userData, !userData.isEmpty {
      do {
        _ = try CloudInit.contentType(of: userData)
      } catch {
        throw .invalidRequest(
          field: "provision.userData",
          reason: "user-data must start with #cloud-config, #!, #cloud-boothook or #include",
          hint: "Begin the user-data with a cloud-init header line such as #cloud-config.")
      }
    }
  }
}

/// One first-boot step as `<vm>/provision.json` records it (R-1004): the command, how long it ran
/// and how it exited. `exitCode` is nil for a step that never ran or whose exit is unknown.
public struct ProvisionStep: Codable, Sendable, Hashable {
  public enum Status: String, Codable, Sendable {
    case succeeded, failed, skipped
  }

  /// `cloud-init`, or `runCommands[<n>]`.
  public var name: String
  public var command: String
  public var status: Status
  public var exitCode: Int?
  public var durationMs: Int?
  /// Why a step failed without an exit code (a timeout, SSH gone).
  public var error: String?

  public init(
    name: String, command: String, status: Status, exitCode: Int? = nil,
    durationMs: Int? = nil, error: String? = nil
  ) {
    self.name = name
    self.command = command
    self.status = status
    self.exitCode = exitCode
    self.durationMs = durationMs
    self.error = error
  }
}

/// `<vm>/provision.json`: every first-boot step in order.
public struct ProvisionReport: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var vm: String
  public var finishedAt: Date
  public var steps: [ProvisionStep]

  public init(vm: String, finishedAt: Date = Date(), steps: [ProvisionStep]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.vm = vm
    self.finishedAt = Date(timeIntervalSince1970: finishedAt.timeIntervalSince1970.rounded(.down))
    self.steps = steps
  }

  /// The first failed step, if any.
  public var failure: ProvisionStep? { steps.first { $0.status == .failed } }

  public static func url(in vmDirectory: URL) -> URL {
    vmDirectory.appending(path: "provision.json")
  }

  public static func logURL(in vmDirectory: URL) -> URL {
    vmDirectory.appending(path: "provision.log")
  }

  /// The report of the VM in `vmDirectory`, or nil when there is none (or it does not decode).
  public static func load(from vmDirectory: URL) -> ProvisionReport? {
    guard let data = try? Data(contentsOf: url(in: vmDirectory)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ProvisionReport.self, from: data)
  }

  public func write(to vmDirectory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: Self.url(in: vmDirectory), options: .atomic)
  }

  /// The `provision_failed` warning for the first failed step, or nil when none failed.
  public func warning(vmDirectory: URL) -> String? {
    guard let step = failure else { return nil }
    let how =
      step.exitCode.map { "exited \($0)" } ?? "failed" + (step.error.map { " (\($0))" } ?? "")
    return "provision_failed: \(vm) step \(step.name) `\(step.command)` \(how); see "
      + Self.logURL(in: vmDirectory).path
  }
}

/// What a start does once the guest answers SSH on first boot (R-1001, R-1004). Returns the
/// start's warnings (`provision_failed: ...`).
public protocol GuestProvisioning: Sendable {
  func provision(_ record: VMRecord, target: SSHTarget) async -> [String]
}

/// The provisioning a start runs over SSH: on a macOS guest, `provision.runCommands` one by one
/// as the login user (after R-606's own first-boot steps). Steps go to `<vm>/provision.json` and
/// their output to `<vm>/provision.log`; a VM that already has a report is not provisioned again.
public struct SSHProvisioner: GuestProvisioning {
  /// Runs one command in the guest; `SSHExecChannel` unless a test replaces it.
  public var exec: @Sendable (SSHTarget, ExecRequest) async throws(VMLabError) -> ExecResult
  /// How long one command may run.
  public var stepTimeout: Duration

  public init(
    stepTimeout: Duration = .seconds(900),
    exec: @escaping @Sendable (SSHTarget, ExecRequest) async throws(VMLabError) -> ExecResult = {
      target, request throws(VMLabError) in
      try await SSHExecChannel(target: target).run(request)
    }
  ) {
    self.exec = exec
    self.stepTimeout = stepTimeout
  }

  public func provision(_ record: VMRecord, target: SSHTarget) async -> [String] {
    let directory = target.vmDirectory
    guard let spec = record.provision, !spec.isEmpty,
      ProvisionReport.load(from: directory) == nil
    else { return [] }
    guard record.guest.os == .macos else { return [] }
    let steps = await runCommands(spec.runCommands, target: target)
    let report = ProvisionReport(vm: record.id, steps: steps)
    do { try report.write(to: directory) } catch {
      return ["provision_failed: cannot write \(ProvisionReport.url(in: directory).path): \(error)"]
    }
    return report.warning(vmDirectory: directory).map { [$0] } ?? []
  }

  /// Runs `commands` in order over SSH; after a failure the rest are `skipped`.
  func runCommands(_ commands: [String], target: SSHTarget) async -> [ProvisionStep] {
    let log = ProvisionLog(url: ProvisionReport.logURL(in: target.vmDirectory))
    var steps: [ProvisionStep] = []
    var failed = false
    for (index, command) in commands.enumerated() {
      let name = "runCommands[\(index)]"
      if failed {
        steps.append(ProvisionStep(name: name, command: command, status: .skipped))
        continue
      }
      log.append("\(name): $ \(command)")
      let started = ContinuousClock.now
      do {
        let result = try await exec(target, ExecRequest(command: command, timeout: stepTimeout))
        log.append(result.stdout + result.stderr)
        let ok = result.exitCode == 0
        log.append("\(name): exit \(result.exitCode) after \(result.durationMs) ms")
        steps.append(
          ProvisionStep(
            name: name, command: command, status: ok ? .succeeded : .failed,
            exitCode: Int(result.exitCode), durationMs: result.durationMs))
        failed = !ok
      } catch {
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        log.append("\(name): \(error.code.rawValue): \(error.message)")
        steps.append(
          ProvisionStep(
            name: name, command: command, status: .failed, durationMs: ms, error: error.message))
        failed = true
      }
    }
    return steps
  }
}

/// Appends lines to `<vm>/provision.log`, creating it on first use.
struct ProvisionLog {
  let url: URL

  func append(_ text: String) {
    guard !text.isEmpty else { return }
    let line = text.hasSuffix("\n") ? text : text + "\n"
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }
}
