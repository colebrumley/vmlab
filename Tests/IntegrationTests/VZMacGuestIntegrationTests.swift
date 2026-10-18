import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// R-605 to R-607 Verify (integration): a `tart clone` of the pulled `macos-base` image boots in
/// our own runner. Needs `tart`, the image pulled into `~/.vmlab/images` (`vmlab images pull
/// macos-base`) and fewer than two macOS guests running on the host. Each test destroys its
/// clone in teardown.
@Suite(.serialized) struct VZMacGuestIntegrationTests {
  static let images = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".vmlab/images")
  static let pulled = ImageStore(home: images.deletingLastPathComponent()).pulled("macos-base")
  static let ready =
    integrationEnabled && pulled?.tartVM != nil && (try? Tart.locate()) != nil
    && FileManager.default.isExecutableFile(atPath: VZRunnerIntegrationTests.runner)

  /// A macOS guest made and started through `VMManager`, destroyed by `teardown`.
  struct Guest {
    let home: URL
    let store: Store
    let manager: VMManager
    let record: VMRecord

    var directory: URL { store.directory(of: record.id) }

    func teardown() async {
      _ = try? await manager.perform(.kill, on: record.id)
      _ = try? await manager.perform(.destroy, on: record.id)
      if let clone = record.tartClone, FileManager.default.fileExists(atPath: clone) {
        _ = try? Tart.locate().delete(URL(filePath: clone).lastPathComponent)
      }
      try? FileManager.default.removeItem(at: home)
    }
  }

  /// Fewer than two macOS guests on the host (Apple's limit, shared by every session).
  static func hostHasRoom() -> Bool {
    let processes = ProcessRunner().run("/bin/ps", ["-Ao", "command"])?.output ?? ""
    let tartGuests = processes.split(separator: "\n").filter { $0.contains("tart run") }.count
    let vmlabGuests = Store(home: images.deletingLastPathComponent()).runningGuests().macOS
    return tartGuests + vmlabGuests < 2
  }

  static func makeGuest(features: [Feature], suffix: String) async throws -> Guest {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-\(suffix)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"), withDestinationURL: images)
    try VZRunnerIntegrationTests.signRunner()
    let store = Store(home: home)
    let registry = BackendRegistry()
    registry.register(
      VZMacBackend(
        store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .seconds(240)))
    let manager = VMManager(store: store, backends: registry)
    let plan = Plan(
      profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      resources: ResourceSpec(cpus: 4, memoryGB: 8), features: features,
      estimatedStartupSeconds: 60)
    let created = try await manager.create(
      VMRecord(id: "", profile: .vzMacOS, guest: plan.guest, features: [], image: "macos-base"),
      plan: plan)
    return Guest(
      home: home, store: store, manager: manager, record: try store.load(id: created.id))
  }

  /// R-605: the clone boots, its lease is found by the clone's MAC, and `ssh admin@<ip>` with the
  /// image password works.
  @Test(.enabled(if: ready && hostHasRoom()), .timeLimit(.minutes(10)))
  func clonedGuestBootsAndAcceptsPasswordSSH() async throws {
    let clock = ContinuousClock()
    let begun = clock.now
    let guest = try await Self.makeGuest(features: [.execSSH], suffix: "m")
    print("clone made after \(clock.now - begun)")
    do {
      let clone = try #require(guest.record.tartClone)
      #expect(clone.hasSuffix("/vms/\(guest.record.id)"))
      let config = try TartVMConfig.read(from: URL(filePath: clone))

      let started = try #require(try await guest.manager.perform(.start, on: guest.record.id))
      #expect(started.state == .running)
      let ip = try #require(started.runtime?.ip, "no DHCP lease for the clone's MAC")
      #expect(DHCPLeases.lookup(mac: MACAddress.normalize(config.macAddress) ?? "") == ip)
      print("lease \(ip) after \(clock.now - begun)")

      let login = try #require(Self.pulled?.login)
      let ssh = PasswordSSH(
        user: login.user, host: ip, password: login.password ?? "", scratch: guest.directory)
      var output: CommandOutput? = nil
      let deadline = clock.now.advanced(by: .seconds(240))
      while clock.now < deadline {
        output = await ssh.run("sw_vers -productVersion", timeout: .seconds(20))
        if output?.status == 0 { break }
        try await Task.sleep(for: .seconds(3))
      }
      #expect(output?.status == 0, "ssh failed: \(output?.output ?? "nothing")")
      print("ssh ok after \(clock.now - begun): \(output?.output ?? "")")
    } catch {
      await guest.teardown()
      throw error
    }
    await guest.teardown()
  }
}
