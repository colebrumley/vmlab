import Darwin
import Foundation
import Testing
import VMLabCore

/// R-304 wired end to end through `vmlab serve`: a qemu-hvf Debian guest crashed with sysrq shows
/// its panic in `vm_inspect` and `vm_logs`.
@Suite(.enabled(if: integrationEnabled), .serialized)
struct PanicIntegrationTests {
  /// qemu-hvf (introspection keeps it on QEMU) and vz-linux (the selector's first choice).
  @Test(arguments: [("qemu-hvf", true), ("vz-linux", false)])
  func sysrqCrashIsDetected(profile: String, introspection: Bool) async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-pn-\(profile.prefix(2))")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab/images"))
    let server = try StdioMCPClient(
      binary: try TwoServersIntegrationTests.vmlabURL(), home: home, tag: "p")
    defer {
      server.terminate()
      for pid in TwoServersIntegrationTests.qemuPIDs(in: home) { kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: home)
    }
    try await server.initialize()
    let requirements: JSONValue = [
      "guest": ["os": "linux", "arch": "arm64"],
      "require": .array(
        ["serial", "exec_ssh"] + (introspection ? ["introspection"] : []).map(JSONValue.string)),
      "resources": ["cpus": 1, "memoryGB": 1, "diskGB": 8],
      "image": "debian-13-arm64",
    ]
    let made = try await server.call(
      "vm_create", ["requirements": requirements, "name": "crashy", "autostart": true])
    try #require(made.isError == false, "\(made.text)")
    try #require(made.value["plan"]?["profile"]?.stringValue == profile, "\(made.text)")
    try #require(made.value["warnings"]?.arrayValue?.isEmpty == true, "\(made.text)")
    if profile == "vz-linux" {
      // The kernel console moves to hvc0 (where the serial channel listens) from the second boot:
      // cloud-init writes the GRUB drop-in on the first.
      for action in ["stop", "start"] {
        let result = try await server.call(
          "vm_lifecycle", ["vm": "crashy", "action": .string(action)])
        try #require(result.isError == false, "\(result.text)")
      }
    }
    let before = try await server.call("vm_inspect", ["vm": "crashy"])
    #expect(before.value["panic"] == .null)

    // The guest dies under the command, so the call fails one way or another; that is expected.
    _ = try await server.call(
      "vm_exec",
      ["vm": "crashy", "command": "echo c | sudo tee /proc/sysrq-trigger", "timeoutSeconds": 15])

    var panic: JSONValue = .null
    let deadline = ContinuousClock.now + .seconds(60)
    while panic == .null, ContinuousClock.now < deadline {
      try await Task.sleep(for: .seconds(1))
      panic = try await server.call("vm_inspect", ["vm": "crashy"]).value["panic"] ?? .null
    }
    let message = panic["message"]?.stringValue ?? ""
    #expect(message.contains("sysrq") || message.contains("Kernel panic"), "\(panic)")
    #expect(panic["kind"] == "panic")
    let logs = try await server.call("vm_logs", ["vm": "crashy", "source": "events"])
    let lines = logs.value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(lines.contains { $0.contains("panic") && $0.contains(message) }, "\(lines)")

    _ = try await server.call("vm_lifecycle", ["vm": "crashy", "action": "destroy"])
  }
}
