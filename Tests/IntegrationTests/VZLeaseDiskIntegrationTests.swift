import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// Audit fixes (integration): a `vz-linux` lease that arrives after `start` stopped waiting still
/// gives SSH and a recorded `runtime.ip`, and `resources.diskGB` larger than the image grows the
/// guest's root filesystem; a Linux guest without a `provision` still gets its first boot
/// recorded.
@Suite(.serialized) struct VZLeaseDiskIntegrationTests {
  static let ready = VZRunnerIntegrationTests.ready

  /// `leaseTimeout: .zero`: start records no address; the manager's SSH wait (exec_ssh) picks up
  /// the lease through `sshEndpoint`, records it, and start returns it.
  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func lateLeaseStillYieldsSSH() async throws {
    let guest = try await VZGuest.boot(features: [.execSSH], tag: "ll", leaseTimeout: .zero)
    defer { guest.cleanUp() }
    #expect(try guest.store.load(id: guest.id).runtime?.ip == guest.ip)
    let vm = try await guest.manager.attach(guest.id)
    let result = try await vm.exec.run(ExecRequest(command: "hostname"))
    #expect(result.exitCode == 0)
  }

  /// Without exec_ssh nothing waits at start; `refreshingAddress` (vm_inspect, vm_list, attach)
  /// records the lease once it appears.
  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func lateLeaseIsRecordedOnRefresh() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-lr")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    VZRunnerIntegrationTests.signRunner()
    let store = Store(home: home)
    let registry = BackendRegistry()
    registry.register(
      VZBackend(
        store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .zero))
    let manager = VMManager(store: store, backends: registry)
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2), features: [.serial], requested: [.serial],
      estimatedStartupSeconds: 30)
    let created = try await manager.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64"),
      plan: plan)
    let started = try #require(try await manager.perform(.start, on: created.id))
    defer {
      if let pid = started.runtime?.pid { kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: home)
    }
    #expect(started.runtime?.ip == nil)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(120))
    var ip: String?
    while ip == nil, clock.now < deadline {
      ip = await manager.refreshingAddress(try store.load(id: created.id)).runtime?.ip
      if ip == nil { try await Task.sleep(for: .seconds(1)) }
    }
    let leased = try #require(ip, "the lease never appeared")
    #expect(try store.load(id: created.id).runtime?.ip == leased)
    let key = store.directory(of: created.id).appending(path: "id_ed25519")
    let up = await VZGuestSSH.poll(key: key, host: leased, command: "true", within: .seconds(180))
    #expect(up?.status == 0, "ssh never answered: \(up?.output ?? "nothing")")
  }

  /// diskGB 12 on a 3 GiB image: the raw clone is extended and cloud-init grows `/`.
  @Test(.enabled(if: ready), .timeLimit(.minutes(9)))
  func diskGBGrowsTheRootFilesystem() async throws {
    let guest = try await VZGuest.boot(
      features: [.execSSH], tag: "dg", resources: ResourceSpec(cpus: 2, memoryGB: 2, diskGB: 12))
    defer { guest.cleanUp() }
    let disk = guest.directory.appending(path: "disk.raw")
    let attributes = try FileManager.default.attributesOfItem(atPath: disk.path)
    #expect((attributes[.size] as? NSNumber)?.uint64Value == 12 << 30)
    let df = try #require(await guest.ssh("df -B1 --output=size / | tail -1"))
    let bytes = UInt64(df.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    print("df /: \(bytes) bytes")
    #expect(bytes > 10 << 30, "root filesystem did not grow: \(df.output)")

    // R-1004 without a provision: the first boot is recorded once cloud-init is done.
    let clock = ContinuousClock()
    // First boot updates and installs packages: about two minutes, more on a busy host.
    let deadline = clock.now.advanced(by: .seconds(360))
    var report: ProvisionReport?
    while report == nil, clock.now < deadline {
      _ = await guest.manager.collectFirstBoot(try guest.store.load(id: guest.id))
      report = ProvisionReport.load(from: guest.directory)
      if report == nil { try await Task.sleep(for: .seconds(2)) }
    }
    if report == nil {
      let status = await guest.ssh("cloud-init status --long; echo exit=$?")
      print("cloud-init status: \(status?.output ?? "no answer")")
    }
    let steps = try #require(report, "cloud-init's outcome was never recorded").steps
    #expect(steps.map(\.name) == ["cloud-init"])
    #expect(steps.first?.status == .succeeded, "\(steps)")
  }
}
