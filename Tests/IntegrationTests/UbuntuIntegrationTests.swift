import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// R-1000 Verify (integration): `ubuntu-24.04-arm64` boots under both engines, and its login user
/// `ubuntu` runs a command over SSH with the VM's key.
@Suite(.serialized) struct UbuntuIntegrationTests {
  static let image = "ubuntu-24.04-arm64"
  static let raw = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".vmlab/images/\(image)/disk.raw")
  static let pulled = integrationEnabled && FileManager.default.fileExists(atPath: raw.path)
  static let vzReady =
    pulled && FileManager.default.isExecutableFile(atPath: VZRunnerIntegrationTests.runner)

  @Test(.enabled(if: pulled), .timeLimit(.minutes(5)))
  func bootsUnderQEMUHVF() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .execSSH, .netNAT], image: Self.image)
    do {
      #expect(guest.startWarnings.isEmpty, "\(guest.startWarnings)")
      let vm = try await guest.manager.attach(guest.record.id)
      let result = try await vm.channel(.exec).run(
        ExecRequest(command: ". /etc/os-release; echo $ID $VERSION_ID; id -un"))
      #expect(result.exitCode == 0)
      #expect(result.stdout == "ubuntu 24.04\nubuntu\n", "\(result)")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  @Test(.enabled(if: vzReady), .timeLimit(.minutes(5)))
  func bootsUnderVZLinux() async throws {
    // Short home: unix socket paths must stay under 104 bytes.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-u")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: Self.raw.deletingLastPathComponent().deletingLastPathComponent())
    try VZRunnerIntegrationTests.signRunner()

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
      VMRecord(id: "", profile: .vzLinux, guest: plan.guest, features: [], image: Self.image),
      plan: plan)
    let dir = store.directory(of: created.id)
    let started = try #require(try await manager.perform(.start, on: created.id))
    defer {
      if let pid = started.runtime?.pid { kill(pid, SIGKILL) }
    }
    #expect(started.state == .running)
    let ip = try #require(started.runtime?.ip, "no DHCP lease for the guest's MAC")

    let clock = ContinuousClock()
    var output: CommandOutput? = nil
    let deadline = clock.now.advanced(by: .seconds(150))
    while clock.now < deadline {
      output = VZLinuxGuestIntegrationTests.ssh(
        key: dir.appending(path: "id_ed25519"), user: "ubuntu", host: ip,
        command: ". /etc/os-release; echo $ID $VERSION_ID")
      if output?.status == 0 { break }
      try await Task.sleep(for: .seconds(2))
    }
    #expect(output?.status == 0, "ssh failed: \(output?.output ?? "nothing")")
    #expect(output?.output.contains("ubuntu 24.04") == true, "\(output?.output ?? "")")

    #expect(try await manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await manager.perform(.destroy, on: created.id) == nil)
  }
}
