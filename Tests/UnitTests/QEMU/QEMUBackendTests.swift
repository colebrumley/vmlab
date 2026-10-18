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
}
