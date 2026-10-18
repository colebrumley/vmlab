import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// R-601 Verify (integration): the full VZ Linux configuration boots `debian-13-arm64` (raw) to
/// `login:` on the virtio console within 60 s, and the VM's own key logs in over SSH at the address
/// read from vmnet's lease file.
@Suite(.serialized) struct VZLinuxGuestIntegrationTests {
  static let ready = VZRunnerIntegrationTests.ready

  static func waitFor(_ text: String, in file: URL, within limit: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
      if let data = try? Data(contentsOf: file),
        String(decoding: data, as: UTF8.self).contains(text)
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return false
  }

  static func ssh(key: URL, user: String, host: String, command: String) -> CommandOutput? {
    ProcessRunner().run(
      "/usr/bin/ssh",
      [
        "-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "\(user)@\(host)", command,
      ])
  }

  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func bootsToLoginOnSerialAndAcceptsSSH() async throws {
    // Short home: unix socket paths must stay under 104 bytes.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-l")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
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
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64"),
      plan: plan)
    let dir = store.directory(of: created.id)
    let console = dir.appending(path: "console.log")

    let clock = ContinuousClock()
    let begun = clock.now
    // The login prompt is watched while start waits for the lease.
    async let sawLogin = Self.waitFor("login:", in: console, within: .seconds(60))
    let started = try #require(try await manager.perform(.start, on: created.id))
    defer {
      if let pid = started.runtime?.pid { kill(pid, SIGKILL) }
    }
    #expect(started.state == .running)
    #expect(await sawLogin, "no login: on the virtio console within 60 s")
    print("login: after \(clock.now - begun)")

    let ip = try #require(started.runtime?.ip, "no DHCP lease for the guest's MAC")
    #expect(try store.load(id: created.id).runtime?.ip == ip)
    #expect(
      DHCPLeases.lookup(mac: VZRunnerConfig.stableMAC(for: created.id)) == ip)

    // cloud-init installs the key early in boot; retry until sshd takes it.
    var output: CommandOutput? = nil
    let deadline = clock.now.advanced(by: .seconds(120))
    while clock.now < deadline {
      output = Self.ssh(
        key: dir.appending(path: "id_ed25519"), user: "debian", host: ip, command: "hostname")
      if output?.status == 0 { break }
      try await Task.sleep(for: .seconds(2))
    }
    #expect(output?.status == 0, "ssh failed: \(output?.output ?? "nothing")")
    print("ssh ok after \(clock.now - begun): \(output?.output ?? "")")

    #expect(try await manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await manager.perform(.destroy, on: created.id) == nil)
  }

  /// The `gui` sentence: with `gui` required, a screenshot through the in-guest VNC server shows
  /// a desktop. The device is built (see MachineDecisionsTests.graphicsOnlyWithGUI); the desktop
  /// and VNC server are R-504's provisioning.
  @Test(.disabled("TODO(R-504): in-guest VNC provisioning is not built yet"))
  func guiGuestShowsADesktop() async throws {}
}
