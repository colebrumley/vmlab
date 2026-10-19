import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

@Suite struct QEMUBackendTests {
  static func record(state: VMState) -> VMRecord {
    VMRecord(
      id: "vm-bh", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [.serial], state: state)
  }

  /// BH-3: a pid file left by a QEMU that died (SIGKILL, host reboot) names whatever process
  /// later got that pid. `kill` of a broken VM SIGKILLed that unrelated process.
  @Test func killOfABrokenVMDoesNotSignalANonQEMUProcessFromAStalePidFile() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-qb-\(UUID())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let backend = QEMUBackend(
      profile: .qemuHVF, store: Store(home: home),
      installation: QEMUInstallation(
        binDirectory: home.appending(path: "bin"), shareDirectory: home.appending(path: "share")))
    let bystander = Process()
    bystander.executableURL = URL(filePath: "/bin/sleep")
    bystander.arguments = ["30"]
    try bystander.run()
    defer { if bystander.isRunning { bystander.terminate() } }
    let layout = backend.layout(of: "vm-bh")
    try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    try "\(bystander.processIdentifier)\n".write(
      to: layout.pidFile, atomically: true, encoding: .utf8)

    try await backend.kill(Self.record(state: .broken))
    try await backend.kill(Self.record(state: .running))
    try await Task.sleep(for: .milliseconds(200))
    #expect(bystander.isRunning, "vmlab SIGKILLed /bin/sleep, which it never started")
  }

  /// CX-15: after QEMU's monitor closes, an exited QEMU leaves the VM stopped with no runtime;
  /// one still running is broken.
  @Test func aMonitorHangUpRecordsTheExitOrBreaksTheVM() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-qh-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    var draft = Self.record(state: .running)
    draft.id = ""
    draft.runtime = VMRuntime(pid: 4242, controlSocket: "/tmp/x.sock")
    draft.name = "gone"
    let gone = try store.create(draft)
    draft.name = "hung"
    let hung = try store.create(draft)

    await QEMUBackend.recordHangUp(
      store: store, id: gone.id, pid: 4242, isAlive: { _ in false }, settle: .zero)
    let stopped = try store.load(id: gone.id)
    #expect(stopped.state == .stopped)
    #expect(stopped.runtime == nil)

    await QEMUBackend.recordHangUp(
      store: store, id: hung.id, pid: 4242, isAlive: { _ in true }, exitWait: .milliseconds(50))
    let broken = try store.load(id: hung.id)
    #expect(broken.state == .broken)
    #expect(broken.brokenReason?.contains("closed its monitor") == true)
  }

  /// CX-25: two concurrent `machine(for:)` both attached, and the loser's monitor stayed
  /// connected (and watched) beside the cached one. They share one attach now.
  @Test func concurrentMachineLookupsShareOneAttach() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-qa-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let backend = QEMUBackend(
      profile: .qemuHVF, store: Store(home: home),
      installation: QEMUInstallation(
        binDirectory: home.appending(path: "bin"), shareDirectory: home.appending(path: "share")))
    let attaches = Counter()
    backend.attachHook.withLock {
      $0 = { layout in
        await attaches.bump()
        try await Task.sleep(for: .milliseconds(200))
        let qmp = try await QMPClient.handshake(
          over: MutableQMPTransport(), timeout: .seconds(2))
        return QEMUMachine(
          layout: layout, pid: 0, qmp: qmp,
          serial: SerialChannel(
            socketPath: "/nonexistent", logURL: layout.directory.appending(path: "serial.log")),
          runtime: VMRuntime(pid: 0, controlSocket: layout.qmpSocket.path))
      }
    }
    let record = Self.record(state: .running)
    async let one = backend.machine(for: record)
    async let two = backend.machine(for: record)
    let (a, b) = try await (one, two)
    #expect(a === b)
    #expect(await attaches.value == 1)
    await a.disconnect()
  }

  /// P3: a net_fast (vmnet) guest has no forwarded port, so it had no SSH endpoint at all. Its
  /// address comes from the vmnet DHCP lease of its MAC and is recorded.
  @Test func aVmnetGuestIsReachedAtItsLease() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-qv-\(UUID())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    var draft = Self.record(state: .running)
    draft.id = ""
    draft.features = [.execSSH, .netFast]
    draft.network = NetworkSpec(mode: .nat)
    draft.plan = Plan(
      profile: .qemuHVF, guest: draft.guest, resources: ResourceSpec(),
      features: [.execSSH, .netFast], requested: [.netFast], estimatedStartupSeconds: 5)
    draft.runtime = VMRuntime(pid: 4242, controlSocket: "/tmp/q.sock")
    let record = try store.create(draft)
    let mac = QEMUCommandLine.mac(for: record.id)
    let leases = home.appending(path: "dhcpd_leases")
    let expiry = String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970), radix: 16)
    try
      "{\n\tname=debian\n\tip_address=192.168.64.33\n\thw_address=1,\(mac)\n\tlease=0x\(expiry)\n}\n"
      .write(to: leases, atomically: true, encoding: .utf8)
    let backend = QEMUBackend(
      profile: .qemuHVF, store: store,
      installation: QEMUInstallation(
        binDirectory: home.appending(path: "bin"), shareDirectory: home.appending(path: "share")),
      leasePath: leases.path)
    #expect(QEMUBackend.usesVmnet(record))
    let endpoint = await backend.sshEndpoint(record, timeout: .seconds(2))
    #expect(endpoint?.host == "192.168.64.33")
    #expect(try store.load(id: record.id).runtime?.ip == "192.168.64.33")
  }

  /// From fix-bh-qemu: a qcow2 named by `-drive file=` passed the path policy, but its header
  /// may name a backing file anywhere (another VM's disk, a file outside the roots), which QEMU
  /// then opens. Every file in the chain passes the policy now.
  @Test(.enabled(if: QEMUCloneTests.installation != nil))
  func aDriveImageBackedByAFileOutsideThePolicyIsRefused() async throws {
    let qemuImg = try #require(QEMUCloneTests.installation).qemuImg
    let root = URL(filePath: "/tmp/vmlab-qc-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    let home = root.appending(path: "home")
    let user = root.appending(path: "user")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = home.appending(path: "vms/vm-other/disk.qcow2")
    try FileManager.default.createDirectory(
      at: secret.deletingLastPathComponent(), withIntermediateDirectories: true)
    let overlay = user.appending(path: "overlay.qcow2")
    let plain = user.appending(path: "plain.qcow2")
    for args in [
      ["create", "-q", "-f", "qcow2", secret.path, "1M"],
      ["create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", secret.path, overlay.path],
      ["create", "-q", "-f", "qcow2", plain.path, "1M"],
    ] {
      let result = try #require(await ProcessRunner().run(qemuImg.path, args))
      try #require(result.status == 0, "\(result.output)")
    }
    let policy = PathPolicy(roots: [root.path])
    let refused = ExtraSpec(qemuArgs: ["-drive", "if=none,id=d1,file=\(overlay.path)"])
    // The check runs qemu-img, so off the cooperative pool.
    let check = { @Sendable (extra: ExtraSpec) async -> Result<Void, VMLabError> in
      await OffPool.run {
        Result { () throws(VMLabError) in
          try QEMUBackend.checkImageChains(
            extra, policy: policy, vmlabHome: home, qemuImg: qemuImg)
        }
      }
    }
    let refusal = await check(refused)
    #expect {
      try refusal.get()
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    let fine = ExtraSpec(qemuArgs: ["-drive", "if=none,id=d1,file=\(plain.path)"])
    try await check(fine).get()
  }
}
