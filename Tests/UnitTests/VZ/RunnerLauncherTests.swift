import Foundation
import Testing
import VMLabCore
import VMLabVZ

struct FixedCommand: CommandRunning {
  var output: String
  func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
    CommandOutput(status: 0, output: output)
  }
}

@Suite struct RunnerLauncherTests {
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/codesign")

  static func fixture(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: name), encoding: .utf8)
  }

  /// Any executable file stands in for the runner; codesign's answer is the fixture.
  static let binary = "/bin/ls"

  @Test func signedRunnerPasses() throws {
    let launcher = VZRunnerLauncher(
      runnerPath: Self.binary,
      commands: FixedCommand(output: try Self.fixture("vmlab-vz-signed.txt")))
    #expect(try launcher.checkedRunner() == Self.binary)
  }

  @Test(arguments: ["unsigned.txt", "virtualization-false.txt"])
  func unentitledRunnerIsHostMissingTool(fixture: String) throws {
    let launcher = VZRunnerLauncher(
      runnerPath: Self.binary, commands: FixedCommand(output: try Self.fixture(fixture)))
    #expect {
      try launcher.checkedRunner()
    } throws: { error in
      let error = error as? VMLabError
      return error?.code == .hostMissingTool && error?.hint == VZRunnerLauncher.signingHint
        && error?.data["entitlement"] == .string(CodeSignature.virtualizationEntitlement)
    }
  }

  @Test func missingRunnerIsHostMissingTool() {
    let launcher = VZRunnerLauncher(
      runnerPath: "/nonexistent/vmlab-vz", commands: FixedCommand(output: ""))
    #expect {
      try launcher.checkedRunner()
    } throws: { ($0 as? VMLabError)?.code == .hostMissingTool }
  }

  @Test func startupFailureReadsTheRunnersErrorLine() throws {
    let error = VMLabError(
      code: .hostMissingTool, message: "no entitlement", hint: VZRunnerLauncher.signingHint)
    let json = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
    let log = "2026-10-18 info vmlab-vz: starting\n" + VZRunnerLauncher.fatalPrefix + json + "\n"
    #expect(VZRunnerLauncher.startupFailure(logText: log, status: 1, logPath: "/v/vz.log") == error)
  }

  @Test func startupFailureWithoutAnErrorLineIsEngineError() {
    let failure = VZRunnerLauncher.startupFailure(
      logText: "a\nb\nsegfault\n", status: 139, logPath: "/v/vz.log")
    #expect(failure.code == .engineError)
    #expect(failure.data["status"] == .number(139))
    #expect(failure.data["tail"] == .string("a\nb\nsegfault"))
  }

  /// R-1202: a bare machine on vz-linux (`image: "none"`, a kernel boot) gets no disk and no seed
  /// from `create`, so its runner configuration has no storage device.
  @Test func aBareMachineHasNoStorageDevice() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzbare-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let kernel = home.appending(path: "Image")
    try Data([0]).write(to: kernel)
    let requirements = try Requirements(
      guest: GuestSpec(os: .linux, arch: .arm64), require: [.serial], image: "none",
      boot: BootSpec(mode: .kernel, kernel: kernel.path))
    let plan = Plan(
      profile: .vzLinux, guest: requirements.guest, resources: ResourceSpec(), features: [.serial],
      estimatedStartupSeconds: 5)
    let store = Store(home: home)
    let record = try store.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: requirements.guest, features: plan.features,
        boot: requirements.boot))
    #expect(record.isBare)
    try await VZBackend(store: store).create(record, plan: plan)
    let dir = store.directory(of: record.id)
    let storage = VZRunnerConfig.storage(in: dir)
    #expect(!storage.rootDisk && !storage.seed)
    let config = try VZRunnerConfig.linux(
      record: record, vmDirectory: dir, boot: record.boot, seed: storage.seed,
      rootDisk: storage.rootDisk)
    #expect(config.disks.isEmpty)
  }
}
