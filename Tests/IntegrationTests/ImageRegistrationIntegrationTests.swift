import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// R-1002 Verify (integration): a raw disk registered with `images register --disk` boots, under
/// vz-linux from its own `disk.raw`, and its login user `vmlab` (made by cloud-init) answers SSH.
@Suite(.serialized) struct ImageRegistrationIntegrationTests {
  static let source = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".vmlab/images/debian-13-arm64/disk.raw")
  static let ready =
    integrationEnabled && FileManager.default.fileExists(atPath: source.path)
    && FileManager.default.isExecutableFile(atPath: VZRunnerIntegrationTests.runner)

  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func registeredRawImageBoots() async throws {
    // Short home: unix socket paths must stay under 104 bytes. The images directory is the
    // test's own, so the registration never touches ~/.vmlab.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-r")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try VZRunnerIntegrationTests.signRunner()

    let images = ImageStore(home: home)
    let record = try await images.registerDisk(
      "local-debian", disk: Self.source, guest: GuestSpec(os: .linux, arch: .arm64),
      format: .raw)
    #expect(record.files["raw"] == "disk.raw" && record.files["qcow2"] == "disk.qcow2")

    let store = Store(home: home)
    let registry = BackendRegistry()
    registry.register(
      VZBackend(
        store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .seconds(90)))
    let manager = VMManager(store: store, backends: registry)
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2), features: [.execSSH, .serial],
      estimatedStartupSeconds: 30)
    let created = try await manager.create(
      VMRecord(id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "local-debian"),
      plan: plan)
    let dir = store.directory(of: created.id)
    let started = try #require(try await manager.performAdmitted(.start, on: created.id))
    defer {
      if let pid = started.runtime?.pid { kill(pid, SIGKILL) }
    }
    let ip = try #require(started.runtime?.ip, "no DHCP lease for the guest's MAC")
    let clock = ContinuousClock()
    var output: CommandOutput? = nil
    let deadline = clock.now.advanced(by: .seconds(150))
    while clock.now < deadline {
      output = VZLinuxGuestIntegrationTests.ssh(
        key: dir.appending(path: "id_ed25519"), user: "vmlab", host: ip, command: "id -un")
      if output?.status == 0 { break }
      try await Task.sleep(for: .seconds(2))
    }
    #expect(output?.status == 0, "ssh failed: \(output?.output ?? "nothing")")
    #expect(output?.output.hasPrefix("vmlab") == true)
    #expect(try await manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await manager.perform(.destroy, on: created.id) == nil)
  }
}
