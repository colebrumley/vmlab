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
  /// The macOS login user's password for `sudo` (and for the first SSH login when the image
  /// records none), needed to mount `share.guest` anywhere but `/Volumes/My Shared Files`.
  /// Decoded from the request only: never encoded, so never in `vm.json`; `VMManager.create`
  /// moves it to `<vm>/sudo.pass` (mode 0600, `SudoPassword`).
  public var sudoPassword: String?

  public init(
    packages: [String] = [], userData: String? = nil, runCommands: [String] = [],
    sudoPassword: String? = nil
  ) {
    self.packages = packages
    self.userData = userData
    self.runCommands = runCommands
    self.sudoPassword = sudoPassword
  }

  enum CodingKeys: String, CodingKey { case packages, userData, runCommands, sudoPassword }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    packages = try c.decodeIfPresent([String].self, forKey: .packages) ?? []
    userData = try c.decodeIfPresent(String.self, forKey: .userData)
    runCommands = try c.decodeIfPresent([String].self, forKey: .runCommands) ?? []
    sudoPassword = try c.decodeIfPresent(String.self, forKey: .sudoPassword)
  }

  /// Everything but `sudoPassword`, which is a secret.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(packages, forKey: .packages)
    try c.encodeIfPresent(userData, forKey: .userData)
    try c.encode(runCommands, forKey: .runCommands)
  }

  /// True when nothing is asked for (a `sudoPassword` alone asks for nothing to run).
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
    if let sudoPassword {
      guard guest.os == .macos else {
        throw .invalidRequest(
          field: "provision.sudoPassword",
          reason: "a Linux guest is provisioned as root by cloud-init and needs no password",
          hint: "Leave provision.sudoPassword out.")
      }
      try SudoPassword.check(sudoPassword)
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

  public static let cloudInit = "cloud-init"

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

  /// The step to blame: the first failed `runCommands` entry (a failing command fails
  /// cloud-init's `runcmd` too), else the first failed step.
  public var failure: ProvisionStep? {
    steps.first { $0.status == .failed && $0.name != ProvisionStep.cloudInit }
      ?? steps.first { $0.status == .failed }
  }

  /// Whether the request's own steps (cloud-init or `runCommands`) were collected already.
  public var hasRequestedSteps: Bool {
    steps.contains { $0.name == ProvisionStep.cloudInit || $0.name.hasPrefix("runCommands[") }
  }

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
  /// Records a first boot that finished since `provision` last looked, without waiting for it
  /// (`vm_inspect`); its warnings. The default records nothing.
  func collect(_ record: VMRecord, target: SSHTarget) async -> [String]
}

extension GuestProvisioning {
  public func collect(_ record: VMRecord, target: SSHTarget) async -> [String] { [] }
}

/// The provisioning a start runs over SSH. On a Linux guest with a `provision` it waits for
/// cloud-init (`cloud-init status --wait`), then reads back the steps the seed's runner recorded
/// (R-1004); a Linux guest without one has its first boot (the R-504 desktop install, the image's
/// own modules) recorded too, but without waiting: one `cloud-init status --long`, at start and
/// again from `collect` (`vm_inspect`) until cloud-init has finished. On a macOS guest it runs
/// `provision.runCommands` one by one as the login user (after R-606's own first-boot steps).
/// Steps go to `<vm>/provision.json` and their output to `<vm>/provision.log`; a VM whose report
/// already has them is not provisioned again.
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
    await firstBoot(record, target: target, wait: !(record.provision?.isEmpty ?? true))
  }

  public func collect(_ record: VMRecord, target: SSHTarget) async -> [String] {
    await firstBoot(record, target: target, wait: false)
  }

  func firstBoot(_ record: VMRecord, target: SSHTarget, wait: Bool) async -> [String] {
    let directory = target.vmDirectory
    // A macOS guest's report already holds the backend's own first-boot steps (R-606: ssh,
    // authorized_keys, hostname, screen_sharing); the request's steps are added after them.
    let existing = ProvisionReport.load(from: directory)
    guard !(existing?.hasRequestedSteps ?? false), existing?.failure == nil else { return [] }
    let spec = record.provision ?? ProvisionSpec()
    let steps: [ProvisionStep]
    switch record.guest.os {
    case .macos:
      guard !spec.isEmpty else { return [] }
      steps = await runCommands(spec.runCommands, target: target)
    case .linux:
      guard
        let collected = await collectCloudInit(spec.runCommands, target: target, wait: wait)
      else { return [] }
      steps = collected
    default:
      return []
    }
    let report = ProvisionReport(vm: record.id, steps: (existing?.steps ?? []) + steps)
    do { try report.write(to: directory) } catch {
      return ["provision_failed: cannot write \(ProvisionReport.url(in: directory).path): \(error)"]
    }
    return report.warning(vmDirectory: directory).map { [$0] } ?? []
  }

  static let waitCommand = "cloud-init status --wait --long"
  static let statusCommand = "cloud-init status --long"
  static let separator = "==vmlab-provision-log=="

  /// The `status:` of `cloud-init status` output (`running`, `done`, `error`, `degraded done`,
  /// `not started`, `disabled`), nil when there is none.
  static func cloudInitStatus(_ output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("status:") {
        return text.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }

  /// Waits for cloud-init to finish (or, without `wait`, asks once and returns nil while it has
  /// not finished, or when SSH does not answer), then reads the runner's `steps.tsv` and log as
  /// root. cloud-init exits 0 when done, 2 when done with recoverable errors (deprecated keys and
  /// the like), 1 on an error. A guest without cloud-init gets one skipped step, so it is not
  /// asked again.
  func collectCloudInit(_ commands: [String], target: SSHTarget, wait: Bool = true) async
    -> [ProvisionStep]?
  {
    let log = ProvisionLog(url: ProvisionReport.logURL(in: target.vmDirectory))
    let step: ProvisionStep
    if wait {
      step = await waitForCloudInit(target: target, log: log)
    } else {
      guard let finished = await finishedCloudInit(target: target, log: log) else { return nil }
      if finished.status == .skipped { return [finished] }
      step = finished
    }
    var steps = [step]

    if !commands.isEmpty {
      let read =
        "cat \(ProvisionPaths.steps) 2>/dev/null; echo \(Self.separator); "
        + "cat \(ProvisionPaths.guestLog) 2>/dev/null; true"
      var recorded: [Int: (exit: Int, ms: Int)] = [:]
      var unread: String?
      do {
        let result = try await exec(
          target, ExecRequest(command: read, timeout: .seconds(60), user: "root"))
        let parts = result.stdout.components(separatedBy: Self.separator + "\n")
        recorded = ProvisionPaths.parseSteps(parts.first ?? "")
        if parts.count > 1 { log.append(parts[1]) }
      } catch {
        unread = "could not read \(ProvisionPaths.steps): \(error.message)"
      }
      var failed = false
      for (index, command) in commands.enumerated() {
        let stepName = "runCommands[\(index)]"
        if let step = recorded[index] {
          let ok = step.exit == 0
          steps.append(
            ProvisionStep(
              name: stepName, command: command, status: ok ? .succeeded : .failed,
              exitCode: step.exit, durationMs: step.ms))
          failed = failed || !ok
        } else if failed {
          steps.append(ProvisionStep(name: stepName, command: command, status: .skipped))
        } else {
          steps.append(
            ProvisionStep(
              name: stepName, command: command, status: .failed,
              error: unread ?? "it did not run (cloud-init never reached runcmd)"))
          failed = true
        }
      }
    }

    if steps.contains(where: { $0.status == .failed }),
      let tail = try? await exec(
        target,
        ExecRequest(
          command: "tail -n 100 /var/log/cloud-init-output.log", timeout: .seconds(60),
          user: "root"))
    {
      log.append("-- the end of /var/log/cloud-init-output.log --")
      log.append(tail.stdout)
    }
    return steps
  }

  /// `cloud-init status --wait --long`: the step once cloud-init has finished.
  func waitForCloudInit(target: SSHTarget, log: ProvisionLog) async -> ProvisionStep {
    let name = ProvisionStep.cloudInit
    log.append("\(name): $ \(Self.waitCommand)")
    let started = ContinuousClock.now
    do {
      let result = try await exec(
        target, ExecRequest(command: Self.waitCommand, timeout: stepTimeout))
      log.append(result.stdout + result.stderr)
      log.append("\(name): exit \(result.exitCode) after \(result.durationMs) ms")
      let ok = result.exitCode == 0 || result.exitCode == 2
      return ProvisionStep(
        name: name, command: Self.waitCommand, status: ok ? .succeeded : .failed,
        exitCode: Int(result.exitCode), durationMs: result.durationMs)
    } catch {
      let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
      log.append("\(name): \(error.code.rawValue): \(error.message)")
      return ProvisionStep(
        name: name, command: Self.waitCommand, status: .failed, durationMs: ms,
        error: error.message)
    }
  }

  /// One short `cloud-init status --long`: the step when cloud-init has finished, a skipped one
  /// when the guest has no cloud-init, nil while it runs or when SSH does not answer (nothing is
  /// logged then, so asking again is cheap).
  func finishedCloudInit(target: SSHTarget, log: ProvisionLog) async -> ProvisionStep? {
    let name = ProvisionStep.cloudInit
    guard
      let result = try? await exec(
        target, ExecRequest(command: Self.statusCommand, timeout: .seconds(15)))
    else { return nil }
    let status = Self.cloudInitStatus(result.stdout)
    if result.exitCode == 127 || status == "disabled" {
      return ProvisionStep(
        name: name, command: Self.statusCommand, status: .skipped, exitCode: Int(result.exitCode),
        error: result.exitCode == 127
          ? "cloud-init is not installed in the guest" : "cloud-init is disabled in the guest")
    }
    guard let status,
      ["done", "error", "degraded done", "degraded error"].contains(status)
    else { return nil }
    log.append("\(name): $ \(Self.statusCommand)")
    log.append(result.stdout + result.stderr)
    log.append("\(name): exit \(result.exitCode) (\(status))")
    let ok = (result.exitCode == 0 || result.exitCode == 2) && !status.hasSuffix("error")
    return ProvisionStep(
      name: name, command: Self.statusCommand, status: ok ? .succeeded : .failed,
      exitCode: Int(result.exitCode))
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

/// Where a Linux guest keeps its first-boot steps (R-1004): `<n>.sh` per `runCommands` entry, the
/// runner cloud-init's `runcmd` calls, `steps.tsv` (`<n> <exit> <ms>` per step run) and the steps'
/// output in `/var/log/vmlab-provision.log`.
public enum ProvisionPaths {
  public static let guestDirectory = "/var/lib/vmlab/provision"
  public static let runner = "\(guestDirectory)/run.sh"
  public static let steps = "\(guestDirectory)/steps.tsv"
  public static let guestLog = "/var/log/vmlab-provision.log"

  /// Runs `0.sh` to `<count-1>.sh` in order, timing each with GNU `date`; stops at the first that
  /// fails, so cloud-init records the failure too.
  public static func runnerScript(count: Int) -> String {
    let indices = (0..<count).map(String.init).joined(separator: " ")
    return """
      #!/bin/sh
      # vmlab first-boot steps (R-1004).
      dir=\(guestDirectory)
      log=\(guestLog)
      : > "$dir/steps.tsv"
      for n in \(indices); do
        echo "== runCommands[$n]" >> "$log"
        start=$(date +%s%3N)
        /bin/sh "$dir/$n.sh" >> "$log" 2>&1 < /dev/null
        code=$?
        end=$(date +%s%3N)
        echo "$n $code $((end - start))" >> "$dir/steps.tsv"
        echo "== runCommands[$n] exit $code" >> "$log"
        [ "$code" -eq 0 ] || exit "$code"
      done

      """
  }

  /// `steps.tsv` as index → (exit, milliseconds).
  public static func parseSteps(_ text: String) -> [Int: (exit: Int, ms: Int)] {
    var steps: [Int: (exit: Int, ms: Int)] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: " ").compactMap { Int($0) }
      guard fields.count == 3 else { continue }
      steps[fields[0]] = (fields[1], fields[2])
    }
    return steps
  }
}

/// The macOS guest's sudo password a request gave (`provision.sudoPassword`), kept beside the VM
/// in `<vm>/sudo.pass` (mode 0600) and never in `vm.json`, a log or a command line: provisioning
/// hands it to `sudo -S` on stdin.
public enum SudoPassword {
  public static let fileName = "sudo.pass"

  public static func url(in vmDirectory: URL) -> URL { vmDirectory.appending(path: fileName) }

  /// `invalid_request` for an empty password or one `sudo -S` cannot read as one line.
  public static func check(_ password: String) throws(VMLabError) {
    guard !password.isEmpty,
      !password.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
    else {
      throw .invalidRequest(
        field: "provision.sudoPassword", reason: "the password is empty or spans lines",
        hint: "Give the guest login user's password on one line.")
    }
  }

  /// Writes `password` to `<vm>/sudo.pass`, readable by its owner only.
  public static func write(_ password: String, in vmDirectory: URL) throws(VMLabError) {
    let file = url(in: vmDirectory)
    let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw VMLabError(
        code: .internal, message: "Cannot write \(file.path): errno \(errno)",
        hint: "Check that the VM directory is writable.")
    }
    defer { close(fd) }
    _ = fchmod(fd, 0o600)
    let bytes = Array(password.utf8)
    let written = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
    guard written == bytes.count else {
      throw VMLabError(
        code: .internal, message: "Cannot write \(file.path): errno \(errno)",
        hint: "Check that the VM directory is writable.")
    }
  }

  /// The password in `<vm>/sudo.pass`, or nil when there is none.
  public static func read(in vmDirectory: URL) -> String? {
    guard let text = try? String(contentsOf: url(in: vmDirectory), encoding: .utf8),
      !text.isEmpty
    else { return nil }
    return text
  }
}
