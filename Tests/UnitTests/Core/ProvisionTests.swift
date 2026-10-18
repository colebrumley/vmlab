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
    #expect(
      Array(runcmd.suffix(2)) == [
        ["sh", "-c", "echo 'a \"quoted\" one' > /tmp/x"], ["sh", "-c", "false"],
      ])
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
