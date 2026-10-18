import Foundation
import Testing

@testable import VMLabCore

@Suite struct EngineProcessTests {
  /// BH-3: a live process is an engine only when its executable is QEMU's or the VZ runner's and,
  /// given a VM directory, one of its arguments lies in it.
  @Test func onlyThisVMsEngineCounts() async throws {
    let root = URL(filePath: "/tmp/vmlab-ep-\(getpid())-\(UInt16.random(in: 0...UInt16.max))")
    let vm = root.appending(path: "vms/vm-a")
    try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fake = root.appending(path: "qemu-system-aarch64")
    try FileManager.default.copyItem(atPath: "/bin/sh", toPath: fake.path)
    let engine = Process()
    engine.executableURL = fake
    // A shell named like QEMU that stays the process (`; :` keeps it from exec'ing sleep); its
    // `$1` stands for QEMU's -pidfile argument inside the VM directory.
    engine.arguments = ["-c", "sleep 30; :", "qemu", vm.appending(path: "qemu.pid").path]
    try engine.run()
    defer { if engine.isRunning { engine.terminate() } }
    let pid = engine.processIdentifier
    try await Task.sleep(for: .milliseconds(100))
    #expect(EngineProcess.isRunning(pid))
    #expect(EngineProcess.isRunning(pid, vmDirectory: vm))
    // The canonical form (/tmp is /private/tmp) names the same directory.
    #expect(EngineProcess.isRunning(pid, vmDirectory: URL(filePath: PathPolicy.canonical(vm.path))))
    #expect(!EngineProcess.isRunning(pid, vmDirectory: root.appending(path: "vms/vm-b")))
    #expect(!EngineProcess.kill(pid, vmDirectory: root.appending(path: "vms/vm-b")))
    #expect(engine.isRunning)
    // This test process is no engine, whatever directory is asked about.
    #expect(!EngineProcess.isRunning(getpid()))
    #expect(!EngineProcess.isRunning(0) && !EngineProcess.isRunning(-1))
    #expect(EngineProcess.kill(pid, vmDirectory: vm))
    engine.waitUntilExit()
    #expect(engine.terminationReason == .uncaughtSignal)
  }
}
