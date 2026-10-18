import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// A booted `vz-linux` Debian guest for integration tests: its own short `VMLAB_HOME` under /tmp
/// (unix socket paths stay under 104 bytes) with the shared image cache linked in, a manager over
/// a `VZBackend`, and SSH to the leased address with the VM's key.
struct VZGuest {
  let home: URL
  let store: Store
  let backend: VZBackend
  let manager: VMManager
  /// The record right after start.
  let record: VMRecord
  let ip: String

  var id: String { record.id }
  var directory: URL { store.directory(of: record.id) }
  var key: URL { directory.appending(path: "id_ed25519") }

  /// Creates and starts a guest planned with `features` (all of them requested) and waits until
  /// SSH answers.
  static func boot(
    features: [Feature], tag: String, share: SharedDirSpec? = nil
  ) async throws -> VZGuest {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-\(tag)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    VZRunnerIntegrationTests.signRunner()
    let store = Store(home: home)
    let backend = VZBackend(
      store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
      leaseTimeout: .seconds(90))
    let registry = BackendRegistry()
    registry.register(backend)
    let manager = VMManager(store: store, backends: registry)
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2), features: features, requested: features,
      estimatedStartupSeconds: 30)
    let created = try await manager.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64",
        share: share),
      plan: plan)
    let started = try #require(try await manager.perform(.start, on: created.id))
    let ip = try #require(started.runtime?.ip, "no DHCP lease for the guest's MAC")
    let guest = VZGuest(
      home: home, store: store, backend: backend, manager: manager, record: started, ip: ip)
    let up = await guest.ssh("true", within: .seconds(180))
    #expect(up?.status == 0, "ssh never answered: \(up?.output ?? "nothing")")
    return guest
  }

  /// Runs `command` over SSH, retrying until it exits 0 or `within` passes; the last result.
  func ssh(_ command: String, within: Duration = .seconds(30)) async -> (
    status: Int32, output: String
  )? {
    await VZGuestSSH.poll(key: key, host: ip, command: command, within: within)
  }

  /// Kills whatever runner the VM has now and removes the home.
  func cleanUp() {
    if let pid = (try? store.load(id: id))?.runtime?.pid { kill(pid, SIGKILL) }
    if let pid = VZRunnerPaths(vmDirectory: directory).recordedPID() { kill(pid, SIGKILL) }
    try? FileManager.default.removeItem(at: home)
  }
}
