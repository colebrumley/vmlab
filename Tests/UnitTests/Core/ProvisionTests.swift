import Foundation
import Synchronization
import Testing

@testable import VMLabCore

/// Answers each command from a table (exit code by command) and records what it was asked.
final class ScriptedExec: Sendable {
  let exits: [String: Int32]
  private let asked = Mutex<[String]>([])
  var commands: [String] { asked.withLock { $0 } }

  init(_ exits: [String: Int32] = [:]) { self.exits = exits }

  func run(_ request: ExecRequest) throws(VMLabError) -> ExecResult {
    asked.withLock { $0.append(request.command) }
    return ExecResult(
      exitCode: exits[request.command] ?? 0, stdout: "out of \(request.command)\n", stderr: "",
      durationMs: 12)
  }
}

/// Hands every start to a fixed list of warnings and records the records it saw.
final class FakeProvisioner: GuestProvisioning {
  let warnings: [String]
  private let seen = Mutex<[String]>([])
  var vms: [String] { seen.withLock { $0 } }

  init(warnings: [String] = []) { self.warnings = warnings }

  func provision(_ record: VMRecord, target: SSHTarget) async -> [String] {
    seen.withLock { $0.append(record.id) }
    return warnings
  }
}

@Suite struct ProvisionTests {
  static func decode(_ json: String) throws -> Requirements {
    try Requirements.decode(json: Data(json.utf8))
  }

  static func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vmlab-provision-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func target(_ directory: URL) -> SSHTarget {
    SSHTarget(
      vm: "vm-abcdef", endpoint: SSHEndpoint(host: "127.0.0.1", port: 2222), user: "admin",
      vmDirectory: directory)
  }

  // MARK: Requirements

  @Test func provisionDecodesAndImpliesCloudInit() throws {
    let r = try Self.decode(
      ##"{"guest":{"os":"linux","arch":"arm64"},"provision":{"packages":["jq","nginx=1.26*"],"userData":"#cloud-config\nhostname: x\n","runCommands":["touch /done"]}}"##
    )
    #expect(r.provision?.packages == ["jq", "nginx=1.26*"])
    #expect(r.provision?.runCommands == ["touch /done"])
    #expect(r.provision?.userData?.hasPrefix("#cloud-config") == true)
    #expect(r.impliedFeatures.map(\.feature) == [.cloudInit])
    let empty = try Self.decode(#"{"guest":{"os":"linux","arch":"arm64"},"provision":{}}"#)
    #expect(empty.provision == ProvisionSpec() && empty.impliedFeatures.isEmpty)
    let again = try JSONDecoder().decode(Requirements.self, from: try JSONEncoder().encode(r))
    #expect(again == r)
  }

  @Test func macOSTakesOnlyRunCommandsOverSSH() throws {
    let ok = try Self.decode(
      #"{"guest":{"os":"macos","arch":"arm64"},"provision":{"runCommands":["brew --version"]}}"#)
    #expect(ok.impliedFeatures.map(\.feature) == [.execSSH])
    for (json, field) in [
      (#"{"packages":["jq"]}"#, "provision.packages"),
      (##"{"userData":"#cloud-config\n"}"##, "provision.userData"),
    ] {
      let error = #expect(throws: VMLabError.self) {
        _ = try Self.decode(#"{"guest":{"os":"macos","arch":"arm64"},"provision":"# + json + "}")
      }
      #expect(error?.code == .invalidRequest)
      #expect(error?.data["field"] == .string(field))
    }
  }

  @Test(arguments: [
    (#"{"packages":["jq; rm -rf /"]}"#, "provision.packages[0]"),
    (#"{"packages":["ok","-flag"]}"#, "provision.packages[1]"),
    (#"{"userData":"packages: [jq]"}"#, "provision.userData"),
    (#"{"runCommands":["echo", "  "]}"#, "provision.runCommands[1]"),
    (#"{"runCommands":"echo"}"#, "provision.runCommands"),
  ])
  func malformedProvisionIsInvalidRequest(json: String, field: String) throws {
    let error = #expect(throws: VMLabError.self) {
      _ = try Self.decode(#"{"guest":{"os":"linux","arch":"arm64"},"provision":"# + json + "}")
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string(field), "\(error?.data ?? [:])")
  }

  // MARK: Seed

  @Test(.enabled(if: RubyYAML.available)) func provisionGoesIntoTheSeed() throws {
    let config = CloudInitTests.base().provisioned(
      ProvisionSpec(
        packages: ["jq", "qemu-guest-agent"], userData: "#cloud-config\nhostname: theirs\n",
        runCommands: ["echo 'a \"quoted\" one' > /tmp/x", "false"]))
    #expect(config.packages == ["jq", "qemu-guest-agent"])
    #expect(config.extraUserData == "#cloud-config\nhostname: theirs\n")
    let ours = try #require(try RubyYAML.parse(CloudInit.cloudConfig(config)) as? [String: Any])
    #expect(ours["packages"] as? [String] == ["qemu-guest-agent", "jq"])
    let runcmd = try #require(ours["runcmd"] as? [[String]])
    #expect(runcmd.last == ["/bin/sh", ProvisionPaths.runner])
    let files = try #require(ours["write_files"] as? [[String: Any]])
    let byPath = Dictionary(
      uniqueKeysWithValues: files.map { ($0["path"] as? String ?? "", $0["content"] as? String) })
    #expect(byPath["\(ProvisionPaths.guestDirectory)/0.sh"] == "echo 'a \"quoted\" one' > /tmp/x\n")
    #expect(byPath["\(ProvisionPaths.guestDirectory)/1.sh"] == "false\n")
    let runner = try #require(byPath[ProvisionPaths.runner] ?? nil)
    #expect(runner.contains("for n in 0 1; do"))
    #expect(files.allSatisfy { $0["permissions"] as? String == "0700" })
    let text = try CloudInit.userData(config)
    #expect(text.contains("hostname: theirs"))
    #expect(text.contains("Merge-Type: \(CloudInit.mergeType)"))
    #expect(CloudInitTests.base().provisioned(nil) == CloudInitTests.base())
  }

  // MARK: macOS runCommands over SSH

  @Test func macOSRunCommandsRunInOrderAndStopAtTheFirstFailure() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let exec = ScriptedExec(["false": 3])
    let provisioner = SSHProvisioner { _, request throws(VMLabError) in try exec.run(request) }
    let record = VMRecord(
      id: "vm-abcdef", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      features: [.execSSH], provision: ProvisionSpec(runCommands: ["true", "false", "echo never"]))
    let warnings = await provisioner.provision(record, target: Self.target(dir))
    #expect(exec.commands == ["true", "false"])
    #expect(warnings.count == 1)
    #expect(
      warnings[0].hasPrefix("provision_failed: vm-abcdef step runCommands[1] `false` exited 3"))
    let report = try #require(ProvisionReport.load(from: dir))
    #expect(report.steps.map(\.status) == [.succeeded, .failed, .skipped])
    #expect(report.steps.map(\.exitCode) == [0, 3, nil])
    #expect(report.steps[1].durationMs == 12)
    #expect(report.failure?.name == "runCommands[1]")
    let log = try String(contentsOf: ProvisionReport.logURL(in: dir), encoding: .utf8)
    #expect(log.contains("runCommands[0]: $ true\nout of true\nrunCommands[0]: exit 0"))

    // Provisioned once: a later start does not run the commands again.
    #expect(await provisioner.provision(record, target: Self.target(dir)).isEmpty)
    #expect(exec.commands.count == 2)
  }

  /// The macOS backend's first-boot steps (R-606) are already in provision.json; runCommands are
  /// added after them, and nothing runs after a failed first boot.
  @Test func macOSRunCommandsFollowTheBackendsFirstBootSteps() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try ProvisionReport(
      vm: "vm-abcdef",
      steps: [
        ProvisionStep(name: "ssh", command: "true", status: .succeeded, exitCode: 0),
        ProvisionStep(name: "hostname", command: "scutil", status: .succeeded, exitCode: 0),
      ]
    ).write(to: dir)
    let exec = ScriptedExec()
    let provisioner = SSHProvisioner { _, request throws(VMLabError) in try exec.run(request) }
    let record = VMRecord(
      id: "vm-abcdef", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      features: [.execSSH], provision: ProvisionSpec(runCommands: ["true"]))
    #expect(await provisioner.provision(record, target: Self.target(dir)).isEmpty)
    let report = try #require(ProvisionReport.load(from: dir))
    #expect(report.steps.map(\.name) == ["ssh", "hostname", "runCommands[0]"])
    #expect(report.hasRequestedSteps)

    // A failed first boot is not followed by the request's commands.
    try ProvisionReport(
      vm: "vm-abcdef",
      steps: [ProvisionStep(name: "ssh", command: "true", status: .failed, error: "no sshd")]
    ).write(to: dir)
    #expect(await provisioner.provision(record, target: Self.target(dir)).isEmpty)
    #expect(exec.commands == ["true"])
  }

  @Test func aCommandThatErrorsIsAFailedStepWithItsReason() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let provisioner = SSHProvisioner { _, _ throws(VMLabError) in
      throw VMLabError(code: .timeout, message: "took too long", hint: "")
    }
    let record = VMRecord(
      id: "vm-abcdef", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      features: [.execSSH], provision: ProvisionSpec(runCommands: ["sleep 9999"]))
    let warnings = await provisioner.provision(record, target: Self.target(dir))
    #expect(warnings.first?.contains("failed (took too long)") == true, "\(warnings)")
    #expect(ProvisionReport.load(from: dir)?.steps.first?.error == "took too long")
  }

  @Test func nothingToDoWithoutAProvisionSpec() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let exec = ScriptedExec()
    let provisioner = SSHProvisioner { _, request throws(VMLabError) in try exec.run(request) }
    let record = VMRecord(
      id: "vm-abcdef", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      features: [.execSSH])
    #expect(await provisioner.provision(record, target: Self.target(dir)).isEmpty)
    #expect(exec.commands.isEmpty && ProvisionReport.load(from: dir) == nil)
  }

  @Test func stepsTSVParses() {
    let steps = ProvisionPaths.parseSteps("0 0 12\n1 3 4500\njunk\n2 x 1\n")
    #expect(steps.count == 2)
    #expect(steps[0]?.exit == 0 && steps[0]?.ms == 12)
    #expect(steps[1]?.exit == 3 && steps[1]?.ms == 4500)
    #expect(ProvisionPaths.runnerScript(count: 3).contains("for n in 0 1 2; do"))
  }

  /// Answers the Linux collection's three commands: the cloud-init wait, the read of steps.tsv
  /// and the log, and the tail of cloud-init's own log.
  final class CloudInitGuest: Sendable {
    let waitExit: Int32
    let tsv: String
    private let asked = Mutex<[ExecRequest]>([])
    var requests: [ExecRequest] { asked.withLock { $0 } }

    init(waitExit: Int32, tsv: String) {
      self.waitExit = waitExit
      self.tsv = tsv
    }

    func run(_ request: ExecRequest) -> ExecResult {
      asked.withLock { $0.append(request) }
      if request.command == SSHProvisioner.waitCommand {
        return ExecResult(
          exitCode: waitExit, stdout: "status: done\n", stderr: "", durationMs: 30_000)
      }
      if request.command.hasPrefix("cat \(ProvisionPaths.steps)") {
        return ExecResult(
          exitCode: 0, stdout: tsv + SSHProvisioner.separator + "\n== runCommands[0]\nhello\n",
          stderr: "")
      }
      return ExecResult(exitCode: 0, stdout: "cloud-init output tail\n", stderr: "")
    }
  }

  static func linux(_ commands: [String], packages: [String] = []) -> VMRecord {
    VMRecord(
      id: "vm-abcdef", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [.execSSH],
      provision: ProvisionSpec(packages: packages, runCommands: commands))
  }

  /// R-1004: the failing runCommands entry is the step provision.json and the warning name.
  @Test func linuxStepsComeBackFromTheGuest() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let guest = CloudInitGuest(waitExit: 1, tsv: "0 0 15\n1 42 7\n")
    let provisioner = SSHProvisioner { _, request in guest.run(request) }
    let warnings = await provisioner.provision(
      Self.linux(["echo hello", "exit 42", "echo never"]), target: Self.target(dir))
    let report = try #require(ProvisionReport.load(from: dir))
    #expect(
      report.steps.map(\.name) == [
        "cloud-init", "runCommands[0]", "runCommands[1]", "runCommands[2]",
      ])
    #expect(report.steps.map(\.status) == [.failed, .succeeded, .failed, .skipped])
    #expect(report.steps.map(\.exitCode) == [1, 0, 42, nil])
    #expect(report.steps.map(\.durationMs) == [30_000, 15, 7, nil])
    #expect(report.steps[2].command == "exit 42")
    #expect(warnings == [report.warning(vmDirectory: dir)!])
    #expect(warnings[0].contains("step runCommands[1] `exit 42` exited 42"))
    // The reads run as root; the failure brings cloud-init's own log into provision.log.
    #expect(guest.requests.dropFirst().allSatisfy { $0.user == "root" })
    let log = try String(contentsOf: ProvisionReport.logURL(in: dir), encoding: .utf8)
    #expect(log.contains("status: done") && log.contains("hello") && log.contains("output tail"))
  }

  @Test func cloudInitFailureAloneIsTheStep() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Packages that would not install: cloud-init errors, and no command was asked for.
    let provisioner = SSHProvisioner { _, request in
      CloudInitGuest(waitExit: 1, tsv: "").run(request)
    }
    let warnings = await provisioner.provision(
      Self.linux([], packages: ["no-such-package"]), target: Self.target(dir))
    #expect(warnings.first?.contains("step cloud-init") == true, "\(warnings)")
    // Recoverable errors (exit 2) are not a failure; a command that never ran is.
    let other = try Self.directory()
    defer { try? FileManager.default.removeItem(at: other) }
    let degraded = SSHProvisioner { _, request in CloudInitGuest(waitExit: 2, tsv: "").run(request)
    }
    let unrun = await degraded.provision(Self.linux(["true"]), target: Self.target(other))
    let report = try #require(ProvisionReport.load(from: other))
    #expect(report.steps[0].status == .succeeded)
    #expect(
      report.steps[1].status == .failed && report.steps[1].error?.contains("did not run") == true)
    #expect(unrun.count == 1)
  }

  @Test func startCarriesTheProvisionersWarnings() async throws {
    let home = try Self.directory()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let backend = FakeBackend(profile: .qemuHVF, store: store)
    let registry = BackendRegistry()
    registry.register(backend)
    let provisioner = FakeProvisioner(warnings: ["provision_failed: x"])
    let manager = VMManager(
      store: store, backends: registry, readiness: FakeReadiness(), provisioner: provisioner)
    backend.reportSSHPort(50022)
    let plan = Plan(
      profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64), resources: ResourceSpec(),
      features: [.execSSH], estimatedStartupSeconds: 1)
    let vm = try await manager.create(
      VMRecord(
        id: "", profile: .qemuHVF, guest: plan.guest, features: [], image: "debian-13-arm64",
        provision: ProvisionSpec(packages: ["jq"])), plan: plan)
    #expect(try store.load(id: vm.id).provision?.packages == ["jq"])
    let outcome = try await manager.run(.start, on: vm.id)
    #expect(outcome.warnings == ["provision_failed: x"])
    #expect(provisioner.vms == [vm.id])

    // A guest that never answers SSH is not provisioned.
    let silent = FakeProvisioner()
    let other = VMManager(
      store: store, backends: registry, readiness: FakeReadiness(warning: "ssh_unreachable: n"),
      provisioner: silent)
    _ = try await other.run(.stop, on: vm.id)
    #expect(try await other.run(.start, on: vm.id).warnings == ["ssh_unreachable: n"])
    #expect(silent.vms.isEmpty)
  }
}
