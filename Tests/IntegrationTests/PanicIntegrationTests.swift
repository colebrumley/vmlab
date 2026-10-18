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

  /// A guest that powers itself off is `stopped` at once (QMP SHUTDOWN), not at the next reconcile.
  @Test func guestPowerOffStopsTheRecord() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-po")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab/images"))
    let server = try StdioMCPClient(
      binary: try TwoServersIntegrationTests.vmlabURL(), home: home, tag: "o")
    defer {
      server.terminate()
      for pid in TwoServersIntegrationTests.qemuPIDs(in: home) { kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: home)
    }
    try await server.initialize()
    let requirements: JSONValue = [
      "guest": ["os": "linux", "arch": "arm64"],
      "require": ["serial", "exec_ssh", "introspection"],
      "resources": ["cpus": 1, "memoryGB": 1, "diskGB": 8], "image": "debian-13-arm64",
    ]
    let made = try await server.call(
      "vm_create", ["requirements": requirements, "name": "off", "autostart": true])
    try #require(made.isError == false, "\(made.text)")
    _ = try await server.call(
      "vm_exec", ["vm": "off", "command": "sudo systemctl poweroff", "timeoutSeconds": 15])
    var state = ""
    let deadline = ContinuousClock.now + .seconds(90)
    while state != "stopped", ContinuousClock.now < deadline {
      try await Task.sleep(for: .seconds(1))
      // The record itself, as the server wrote it.
      state = (try? Store(home: home).find("off").state.rawValue) ?? ""
    }
    #expect(state == "stopped")
    let logs = try await server.call("vm_logs", ["vm": "off", "source": "events"])
    let lines = logs.value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(lines.contains { $0.contains("running -> stopped: the guest powered off") }, "\(lines)")
    _ = try await server.call("vm_lifecycle", ["vm": "off", "action": "destroy"])
  }

  /// A panic while no vmlab process holds the serial socket: QEMU's console.log keeps it, and the
  /// next server finds it when it attaches at start.
  @Test func panicWithNobodyWatchingIsFoundByTheNextServer() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-nw")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab/images"))
    let binary = try TwoServersIntegrationTests.vmlabURL()
    let first = try StdioMCPClient(binary: binary, home: home, tag: "1")
    var second: StdioMCPClient?
    defer {
      first.terminate()
      second?.terminate()
      for pid in TwoServersIntegrationTests.qemuPIDs(in: home) { kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: home)
    }
    try await first.initialize()
    let requirements: JSONValue = [
      "guest": ["os": "linux", "arch": "arm64"],
      "require": ["serial", "exec_ssh", "introspection"],
      "resources": ["cpus": 1, "memoryGB": 1, "diskGB": 8], "image": "debian-13-arm64",
    ]
    let made = try await first.call(
      "vm_create", ["requirements": requirements, "name": "lonely", "autostart": true])
    try #require(made.isError == false, "\(made.text)")
    let job = try await first.call(
      "vm_exec",
      [
        "vm": "lonely", "background": true,
        "command": "sleep 8; echo c | sudo tee /proc/sysrq-trigger",
      ])
    try #require(job.isError == false, "\(job.text)")
    first.terminate()  // nobody holds the serial socket now
    try await Task.sleep(for: .seconds(20))
    let store = Store(home: home)
    let log = EventLog(vmDirectory: store.directory(of: try store.find("lonely").id))
    #expect(try await log.latestPanic() == nil)  // nobody was watching

    let next = try StdioMCPClient(binary: binary, home: home, tag: "2")
    second = next
    try await next.initialize()
    var panic: JSONValue = .null
    let deadline = ContinuousClock.now + .seconds(30)
    while panic == .null, ContinuousClock.now < deadline {
      try await Task.sleep(for: .seconds(1))
      panic = try await next.call("vm_inspect", ["vm": "lonely"]).value["panic"] ?? .null
    }
    let message = panic["message"]?.stringValue ?? ""
    #expect(message.contains("sysrq") || message.contains("Kernel panic"), "\(panic)")
    _ = try await next.call("vm_lifecycle", ["vm": "lonely", "action": "kill"])
  }
}
