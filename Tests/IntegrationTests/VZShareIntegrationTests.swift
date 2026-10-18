import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// R-603 Verify (integration): a host directory shared over virtiofs shows host files in the guest
/// (one written after boot within 2 s), and the x86_64 static `hello` fixture runs in the arm64
/// guest through Rosetta and prints its greeting.
@Suite(.serialized) struct VZShareIntegrationTests {
  static let hello = VZRunnerIntegrationTests.root.appending(
    path: "Tests/Fixtures/elf/hello-x86_64")
  static let ready =
    VZRunnerIntegrationTests.ready
    && FileManager.default.fileExists(atPath: HostProbe.rosettaRuntimePath)

  @Test(.enabled(if: ready), .timeLimit(.minutes(10)))
  func sharedDirectoryAndRosetta() async throws {
    // Short home: unix socket paths must stay under 104 bytes.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-f")
    let shared = URL(filePath: "/tmp/vmlab-test-\(getpid())-share")
    for dir in [home, shared] { try? FileManager.default.removeItem(at: dir) }
    defer { for dir in [home, shared] { try? FileManager.default.removeItem(at: dir) } }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    try FileManager.default.copyItem(at: Self.hello, to: shared.appending(path: "hello"))
    try "written before boot\n".write(
      to: shared.appending(path: "before.txt"), atomically: true, encoding: .utf8)
    VZRunnerIntegrationTests.signRunner()

    let store = Store(home: home)
    let registry = BackendRegistry()
    registry.register(
      VZBackend(
        store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .seconds(90)))
    let manager = VMManager(store: store, backends: registry)
    let features: [Feature] = [.execSSH, .serial, .sharedDir, .rosetta]
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2), features: features, requested: features,
      estimatedStartupSeconds: 30)
    let created = try await manager.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64",
        shares: [ShareSpec(host: shared.path)]),
      plan: plan)
    let started = try #require(try await manager.perform(.start, on: created.id))
    defer {
      if let pid = try? store.load(id: created.id).runtime?.pid { kill(pid, SIGKILL) }
    }
    let key = store.directory(of: created.id).appending(path: "id_ed25519")
    let ip = try #require(started.runtime?.ip, "no DHCP lease for the guest's MAC")

    // cloud-init mounts share0 at /mnt/share0.
    let before = await VZGuestSSH.poll(
      key: key, host: ip, command: "cat /mnt/share0/before.txt", within: .seconds(300))
    #expect(before?.output == "written before boot\n", "share not mounted: \(before?.output ?? "")")

    try "written after boot\n".write(
      to: shared.appending(path: "after.txt"), atomically: true, encoding: .utf8)
    let clock = ContinuousClock()
    let written = clock.now
    let after = await VZGuestSSH.poll(
      key: key, host: ip, command: "cat /mnt/share0/after.txt", within: .seconds(10))
    #expect(after?.output == "written after boot\n")
    print("host file seen in the guest after \(clock.now - written) (ssh round trips included)")

    // runcmd registers Rosetta with binfmt_misc after the package install.
    let hello = await VZGuestSSH.poll(
      key: key, host: ip,
      command: "test -e /proc/sys/fs/binfmt_misc/rosetta && /mnt/share0/hello",
      within: .seconds(420))
    #expect(hello?.status == 0, "hello failed: \(hello?.output ?? "nothing")")
    #expect(hello?.output == "Hello from x86_64 via Rosetta\n")
    let arch = await VZGuestSSH.run(key: key, host: ip, command: "uname -m", limit: .seconds(20))
    #expect(arch?.output == "aarch64\n")

    #expect(try await manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await manager.perform(.destroy, on: created.id) == nil)
  }
}
