import Foundation
import Testing
import VMLabCore

@testable import VMLabVZ

@Suite struct VZBackendTests {
  /// BH-3: a `vz.pid` left by a runner that died names whatever process later got that pid;
  /// kill and destroy must not SIGKILL it, nor wait for it to exit.
  @Test func killDoesNotSignalANonRunnerProcessFromAStalePidFile() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let record = try store.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64), features: [],
        state: .broken))
    let bystander = Process()
    bystander.executableURL = URL(filePath: "/bin/sleep")
    bystander.arguments = ["30"]
    try bystander.run()
    defer { if bystander.isRunning { bystander.terminate() } }
    let backend = VZBackend(store: store)
    try "\(bystander.processIdentifier)\n".write(
      to: backend.paths(record).pidFile, atomically: true, encoding: .utf8)
    try await backend.kill(record)
    try await backend.destroy(record)
    try await Task.sleep(for: .milliseconds(200))
    #expect(bystander.isRunning, "vmlab SIGKILLed /bin/sleep, which it never started")
  }

  /// CX-15: nothing observed the runner's exit, so after a guest shutdown or a SIGKILL the VM
  /// showed running until the next restart. The backend watches the runner pid and records it.
  @Test(.timeLimit(.minutes(1))) func aRunnerExitIsRecordedWhenItHappens() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzx-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let runner = Process()
    runner.executableURL = URL(filePath: "/bin/sleep")
    runner.arguments = ["0.3"]
    try runner.run()
    let pid = runner.processIdentifier
    let record = try store.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64), features: [],
        state: .running, runtime: VMRuntime(pid: pid, controlSocket: "/tmp/none.sock")))
    let backend = VZBackend(store: store)
    backend.watchExit(id: record.id, pid: pid, isRunning: { LivenessProbe.processExists($0) })
    let deadline = ContinuousClock.now + .seconds(30)
    while try store.load(id: record.id).state == .running, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let stopped = try store.load(id: record.id)
    #expect(stopped.state == .stopped)
    #expect(stopped.runtime == nil)

    // A pid already gone when watched is recorded too.
    let gone = try store.create(
      VMRecord(
        id: "", name: "gone", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [], state: .running,
        runtime: VMRuntime(pid: 999_999, controlSocket: "/tmp/none.sock")))
    backend.watchExit(id: gone.id, pid: 999_999, isRunning: { _ in false })
    while try store.load(id: gone.id).state == .running, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try store.load(id: gone.id).state == .stopped)
  }

  /// CX-30: a registered kernel-only image was refused on vz-linux (no raw disk) though QEMU
  /// boots it. With boot.mode kernel it gets no disk and no seed, and the runner config none.
  @Test func aKernelOnlyImageBootsWithoutADisk() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzkn-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let images = ImageStore(home: home)
    let imageDir = images.imageDirectory("tiny-kernel")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
    try Data("kernel".utf8).write(to: imageDir.appending(path: "Image"))
    let pulled = PulledImage(
      name: "tiny-kernel", guest: GuestSpec(os: .linux, arch: .arm64), source: "fixture",
      format: .kernel, checksum: nil, files: ["kernel": "Image"], login: ImageLogin(user: "root"),
      pulledAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(pulled).write(to: imageDir.appending(path: "image.json"))
    let store = Store(home: home)
    var draft = VMRecord(
      id: "", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64), features: [],
      image: "tiny-kernel")
    let plan = Plan(
      profile: .vzLinux, guest: draft.guest, resources: ResourceSpec(), features: [],
      estimatedStartupSeconds: 5)
    // Disk boot of a kernel says why it cannot work.
    let diskBoot = try store.create(draft)
    let error = await #expect(throws: VMLabError.self) {
      try await VZBackend(store: store).create(diskBoot, plan: plan)
    }
    #expect(error?.message.contains("boot.mode kernel") == true)

    draft.name = "kernel"
    draft.boot = BootSpec(mode: .kernel, kernel: imageDir.appending(path: "Image").path)
    let record = try store.create(draft)
    try await VZBackend(store: store).create(record, plan: plan)
    let dir = store.directory(of: record.id)
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "disk.raw").path))
    let config = try VZRunnerConfig.linux(
      record: record, vmDirectory: dir, boot: record.boot, seed: false, rootDisk: false)
    #expect(config.disks.isEmpty)
  }

  static let tools =
    FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")
    && FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")

  /// create clones the raw disk, makes the VM's key and a seed for the image's user with the
  /// console on hvc0 and the NAT NIC identified to DHCP by its stable MAC.
  @Test(.enabled(if: tools)) func createWritesDiskKeyAndSeed() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzb-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let images = ImageStore(home: home)
    let imageDir = images.imageDirectory("debian-13-arm64")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
    try Data("raw disk".utf8).write(to: imageDir.appending(path: "disk.raw"))
    let pulled = PulledImage(
      name: "debian-13-arm64", guest: GuestSpec(os: .linux, arch: .arm64), source: "fixture",
      format: .raw, checksum: nil, files: ["raw": "disk.raw"], login: ImageLogin(user: "debian"),
      pulledAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(pulled).write(to: imageDir.appending(path: "image.json"))

    let store = Store(home: home)
    let record = try store.create(
      VMRecord(
        id: "", name: "Dev.Box_1", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [.execSSH], image: "debian-13-arm64"))
    let backend = VZBackend(store: store)
    let plan = Plan(
      profile: .vzLinux, guest: record.guest, resources: ResourceSpec(), features: [.execSSH],
      estimatedStartupSeconds: 30)
    try await backend.create(record, plan: plan)

    let dir = store.directory(of: record.id)
    // Grown (sparse) to the Linux default of 32 GiB, the image's bytes first.
    let disk = dir.appending(path: "disk.raw")
    #expect(VZDisk.size(of: disk) == 32 << 30)
    #expect(try FileHandle(forReadingFrom: disk).read(upToCount: 8) == Data("raw disk".utf8))
    let publicKey = try String(
      contentsOf: dir.appending(path: "id_ed25519.pub"), encoding: .utf8)
    #expect(publicKey.hasPrefix("ssh-ed25519 "))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "seed.iso").path))
    let userData = try String(contentsOf: dir.appending(path: "seed/user-data"), encoding: .utf8)
    #expect(userData.contains(publicKey.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(userData.contains("serial-getty@hvc0.service"))
    #expect(userData.contains("name: \"debian\""))
    #expect(userData.contains("\"dev-box-1\""))
    let network = try String(
      contentsOf: dir.appending(path: "seed/network-config"), encoding: .utf8)
    #expect(network.contains(VZRunnerConfig.stableMAC(for: record.id)))
    #expect(network.contains("dhcp-identifier"))

    // A second create keeps the key.
    try await backend.create(record, plan: plan)
    #expect(
      try String(contentsOf: dir.appending(path: "id_ed25519.pub"), encoding: .utf8) == publicKey)
  }

  /// resources.diskGB extends the raw clone (sparse) to that many GiB; below the image's disk it
  /// is refused with invalid_request before anything is copied.
  @Test func diskGBGrowsTheRawCloneAndRefusesShrinking() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzdisk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let disk = dir.appending(path: "disk.raw")
    try Data("raw disk".utf8).write(to: disk)
    try VZDisk.grow(disk, toBytes: 3 << 30)
    #expect(VZDisk.size(of: disk) == 3 << 30)
    #expect(try FileHandle(forReadingFrom: disk).read(upToCount: 8) == Data("raw disk".utf8))
    try VZDisk.grow(disk, toBytes: 1 << 30)
    #expect(VZDisk.size(of: disk) == 3 << 30)
    do {
      try VZDisk.refuseShrink(current: 3 << 30, toBytes: 2 << 30, diskGB: 2, image: "debian")
      Issue.record("shrinking was accepted")
    } catch {
      #expect(error.code == .invalidRequest)
      #expect(error.data["field"] == .string("resources.diskGB"))
    }
  }

  /// Rosetta is shared only when the request asked for it, not whenever the profile grants it.
  @Test func rosettaOnlyWhenRequested() {
    var record = VMRecord(
      id: "vm-abc234", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [.execSSH, .rosetta])
    #expect(!VZRunnerConfig.wantsRosetta(record))
    record.plan = Plan(
      profile: .vzLinux, guest: record.guest, resources: ResourceSpec(),
      features: record.features, requested: [.rosetta], estimatedStartupSeconds: 30)
    #expect(VZRunnerConfig.wantsRosetta(record))
  }

  @Test func hostnameIsADNSLabel() {
    func record(_ name: String) -> VMRecord {
      VMRecord(
        id: "vm-abc234", name: name, profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [])
    }
    #expect(VZBackend.hostname(for: record("Web Server.01")) == "web-server-01")
    #expect(VZBackend.hostname(for: record("---")) == "vm-abc234")
    #expect(VZBackend.hostname(for: record(String(repeating: "a", count: 80))).count == 63)
  }

  /// R-504: a plan that requested gui gets the desktop with an in-guest VNC server whose password
  /// is in `<vm>/vnc.pass`; one that did not gets nothing.
  @Test func guiStackFollowsThePlan() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzgui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    func plan(_ requested: [Feature]) -> Plan {
      Plan(
        profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64), resources: ResourceSpec(),
        features: [.gui, .serial], requested: requested, estimatedStartupSeconds: 0)
    }
    #expect(try VZBackend.guiStack(plan: plan([.serial]), vmDirectory: dir) == nil)
    let stack = try #require(try VZBackend.guiStack(plan: plan([.gui]), vmDirectory: dir))
    let password = try String(contentsOf: dir.appending(path: "vnc.pass"), encoding: .utf8)
    #expect(stack.vncPassword.map { $0 + "\n" } == password)
    #expect(stack.vncPort == 5900)
  }

  /// A lease that appears after `start` stopped waiting still yields the SSH endpoint, and it is
  /// recorded as `runtime.ip` for that runner only (both VZ backends).
  @Test(arguments: [Profile.vzLinux, .vzMacOS]) func lateLeaseIsWaitedForAndRecorded(
    profile: Profile
  ) async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzlease-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    var record = try store.create(
      VMRecord(
        id: "", profile: profile, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [.execSSH]))
    record = try store.update(id: record.id) {
      $0.state = .running
      $0.runtime = VMRuntime(pid: 4242, controlSocket: "/nonexistent/control.sock")
    }
    let mac = VZRunnerConfig.stableMAC(for: record.id)
    try VZRunnerConfig(
      cpus: 1, memoryBytes: 1 << 30, boot: .efi(variableStore: "efi.bin"), disks: [],
      network: [.nat(macAddress: mac)]
    )
    .write(to: VZRunnerPaths(vmDirectory: store.directory(of: record.id)).config)
    let leases = home.appending(path: "dhcpd_leases")
    let backend: any Backend =
      profile == .vzLinux
      ? VZBackend(store: store, leasePath: leases.path)
      : VZMacBackend(store: store, leasePath: leases.path)

    #expect(await backend.sshEndpoint(record, timeout: .zero) == nil)
    let expires = String(Int(Date().timeIntervalSince1970) + 3600, radix: 16)
    let writer = Task {
      try await Task.sleep(for: .milliseconds(600))
      try Data(
        "{\n\tname=late\n\tip_address=192.168.64.77\n\thw_address=1,\(mac)\n\tlease=0x\(expires)\n}\n"
          .utf8
      ).write(to: leases)
    }
    let endpoint = await backend.sshEndpoint(record, timeout: .seconds(10))
    try await writer.value
    #expect(endpoint == SSHEndpoint(host: "192.168.64.77"))
    #expect(try store.load(id: record.id).runtime?.ip == "192.168.64.77")

    // A runner that is no longer the recorded one does not overwrite the record.
    try store.update(id: record.id) {
      $0.runtime = VMRuntime(pid: 5151, controlSocket: "/nonexistent/control.sock")
    }
    #expect(await backend.sshEndpoint(record, timeout: .zero) != nil)
    #expect(try store.load(id: record.id).runtime?.ip == nil)
  }
}
