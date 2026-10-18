import Foundation
import Testing
import VMLabCore
import VMLabVZ

@testable import VMLabMCP

/// R-602 Verify (integration): on a `vz-linux` guest, `vm_serial wait "login:"`, `write "root\n"`,
/// and the prompt appears, through the same `SerialChannel` QEMU guests use, on the runner's
/// `serial.sock` bridge of the virtio console.
@Suite(.serialized) struct VZSerialIntegrationTests {
  static let ready = VZRunnerIntegrationTests.ready

  @Test(.enabled(if: ready), .timeLimit(.minutes(10)))
  func serialWaitWriteAndPrompt() async throws {
    // Short home: unix socket paths must stay under 104 bytes.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-s")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    VZRunnerIntegrationTests.signRunner()

    let registry = BackendRegistry()
    let store = Store(home: home)
    registry.register(
      VZBackend(
        store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .seconds(90)))
    let context = ToolContext(home: home, backends: registry)
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2), features: [.execSSH, .serial],
      estimatedStartupSeconds: 30)
    let created = try await context.manager.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64"),
      plan: plan)
    var started = try #require(try await context.manager.perform(.start, on: created.id))
    defer {
      if let pid = try? store.load(id: created.id).runtime?.pid { kill(pid, SIGKILL) }
    }
    #expect(
      started.runtime?.serialSocket
        == store.directory(of: created.id)
        .appending(path: "serial.sock").path)

    func serial(_ arguments: [String: JSONValue]) async throws -> ToolResult {
      var arguments = arguments
      arguments["vm"] = .string(created.id)
      return try await ToolHandlers.call(
        "vm_serial", arguments: .object(arguments), context: context)
    }
    let login = try await serial([
      "action": .string("wait"), "pattern": .string("login: "), "timeoutSeconds": .number(90),
    ])
    #expect(login.value["matched"] == .string("login: "))
    let offset = try #require(login.value["offset"]?.numberValue)
    _ = try await serial(["action": .string("write"), "text": .string("root\n")])
    let prompt = try await serial([
      "action": .string("wait"), "pattern": .string("Password: ?$|# ?$"),
      "since": .number(offset), "timeoutSeconds": .number(30),
    ])
    #expect(prompt.value["matched"] != nil)
    print("after root: \(prompt.value["text"]?.stringValue ?? "")")

    // cloud-init put console=hvc0 on the kernel command line; from the next boot the kernel's
    // own messages are on the serial channel, captured from the first byte.
    let dir = store.directory(of: created.id)
    let ip = try #require(started.runtime?.ip, "no DHCP lease for the guest's MAC")
    // runcmd (update-grub) runs after cloud-init's package install, which is slow on a busy
    // host; poll with a hard limit per ssh so a stalled session cannot hang the test.
    var updated = false
    let deadline = ContinuousClock.now + .seconds(420)
    while ContinuousClock.now < deadline, !updated {
      updated = await Self.ssh(
        key: dir.appending(path: "id_ed25519"), host: ip,
        command: "grep -q console=hvc0 /boot/grub/grub.cfg", limit: .seconds(20))
      if !updated { try await Task.sleep(for: .seconds(3)) }
    }
    #expect(updated, "cloud-init did not put console=hvc0 in grub.cfg")
    _ = try await context.manager.perform(.stop, on: created.id)
    started = try #require(try await context.manager.perform(.start, on: created.id))
    _ = try await serial([
      "action": .string("wait"), "pattern": .string("login: "), "timeoutSeconds": .number(90),
    ])
    let boot = try await serial(["action": .string("read"), "since": .number(0)])
    let text = boot.value["text"]?.stringValue ?? ""
    print("second boot transcript head:\n\(text.prefix(600))")
    // The kernel's own lines, from when the virtio console registered (the boot console before
    // it is not replayed), ahead of systemd and the login prompt.
    #expect(text.hasPrefix("[    0."), "the serial channel does not start with kernel output")
    #expect(text.contains("Freeing unused kernel memory"), "kernel messages are not on hvc0")

    #expect(try await context.manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await context.manager.perform(.destroy, on: created.id) == nil)
  }

  /// `ssh debian@host command` with the VM's key; true on exit 0. Killed after `limit`.
  static func ssh(key: URL, host: String, command: String, limit: Duration) async -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ssh")
    process.arguments = [
      "-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
      "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
      "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "debian@\(host)", command,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    let deadline = ContinuousClock.now + limit
    while process.isRunning, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(200))
    }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      return false
    }
    return process.terminationStatus == 0
  }
}
