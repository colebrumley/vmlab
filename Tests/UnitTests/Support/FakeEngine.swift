import Foundation
import Testing
import VMLabCore

/// A process `EngineProcess` takes for a VM's QEMU: an ad-hoc-signed copy of bash named
/// `qemu-system-aarch64` whose arguments name the VM directory's `qemu.pid`, which it is written
/// to. (A copied platform binary keeps Apple's signature and is SIGKILLed at exec; macOS's
/// /bin/sh re-execs bash, so bash itself is copied.)
final class FakeEngine: Sendable {
  let process: Process
  let root: URL

  var pid: Int32 { process.processIdentifier }

  init(vmDirectory: URL) throws {
    root = URL(filePath: "/tmp/vmlab-fe-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appending(path: "qemu-system-aarch64")
    try FileManager.default.copyItem(atPath: "/bin/bash", toPath: fake.path)
    let sign = Process()
    sign.executableURL = URL(filePath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", fake.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    try #require(sign.terminationStatus == 0, "codesign of the fake engine failed")
    let pidFile = vmDirectory.appending(path: "qemu.pid")
    process = Process()
    process.executableURL = fake
    process.arguments = ["-c", "sleep 60; :", "qemu", pidFile.path]
    try process.run()
    try "\(process.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
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
