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
}
