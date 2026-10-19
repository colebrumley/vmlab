import Foundation
import Testing
import VMLabCore

/// A process `EngineProcess` takes for a VM's QEMU: a small program built as
/// `qemu-system-aarch64` whose arguments name the VM directory's `qemu.pid`, which it is written
/// to.
final class FakeEngine: Sendable {
  let process: Process
  let root: URL

  var pid: Int32 { process.processIdentifier }

  /// Building the program, and its first exec (macOS assesses a new executable then), wait off
  /// the cooperative pool.
  init(vmDirectory: URL) async throws {
    let root = URL(filePath: "/tmp/vmlab-fe-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = try await Self.build(in: root)
    let pidFile = vmDirectory.appending(path: "qemu.pid")
    let process = Process()
    process.executableURL = fake
    process.arguments = ["qemu", pidFile.path]
    try await TestProcess.start(process)
    self.process = process
    try "\(process.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
  }

  /// Compiles `<directory>/qemu-system-aarch64`, a program that sleeps for a minute whatever its
  /// arguments, and returns its URL. Compiled, not a copy of /bin/bash: a system binary is
  /// arm64e, and an ad-hoc-signed arm64e copy is SIGKILLed at exec on hosts without the arm64e
  /// preview ABI (the macOS 15 CI runners); the linker signs a plain arm64 build itself.
  static func build(in directory: URL) async throws -> URL {
    let source = directory.appending(path: "fake-engine.c")
    let binary = directory.appending(path: "qemu-system-aarch64")
    try "#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n"
      .write(to: source, atomically: true, encoding: .utf8)
    let cc = try await TestProcess.run(
      "/usr/bin/xcrun", ["clang", "-o", binary.path, source.path])
    try #require(cc.status == 0, "building the fake engine failed")
    return binary
  }

  /// Polls (not `waitUntilExit`, which can miss the exit on a concurrency thread) for the exit.
  func waitForExit(within limit: Duration = .seconds(10)) async throws -> Bool {
    let deadline = ContinuousClock.now + limit
    while process.isRunning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    return !process.isRunning
  }

  deinit {
    if process.isRunning { process.terminate() }
    try? FileManager.default.removeItem(at: root)
  }
}
