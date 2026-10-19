import Foundation
import Testing
import VMLabCore
import VMLabVZ

@testable import VMLabMCP

/// vz-console-boot (integration): a fresh `vz-linux` Debian guest boots its own kernel through
/// `VZLinuxBootLoader` with `console=hvc0`, so its very first boot has the kernel's messages on
/// the serial channel; the boot is read from the disk again at every start, so a change the guest
/// makes to its boot configuration is what the next start boots.
@Suite(.serialized) struct VZDiskBootIntegrationTests {
  static let ready = VZRunnerIntegrationTests.ready

  @Test(.enabled(if: ready), .timeLimit(.minutes(15)))
  func firstBootHasTheKernelOnTheConsoleAndEveryStartRereadsTheDisk() async throws {
    // Short home: unix socket paths must stay under 104 bytes.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-db")
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
    let context = ToolContext(home: home, backends: registry, startGate: IntegrationAdmission.gate)
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2), features: [.execSSH, .serial],
      estimatedStartupSeconds: 30)
    let created = try await context.manager.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64"),
      plan: plan)
    let dir = store.directory(of: created.id)
    defer {
      if let pid = try? store.load(id: created.id).runtime?.pid { kill(pid, SIGKILL) }
    }
    let first = try await context.manager.runAdmitted(.start, on: created.id)
    #expect(first.warnings.allSatisfy { !$0.contains("EFI") }, "\(first.warnings)")
    let started = try #require(first.record)

    let consoleLog = dir.appending(path: "console.log")
    /// `console.log` from byte `since` on once it holds a kernel line stamped within the first
    /// second of boot (read from the log: a busy first boot prints more than the serial channel
    /// keeps in memory); "" when none came within 90 s.
    func kernelOutput(since: Int) async throws -> String {
      let deadline = ContinuousClock.now + .seconds(90)
      while ContinuousClock.now < deadline {
        let data = (try? Data(contentsOf: consoleLog)) ?? Data()
        let text = String(decoding: data.dropFirst(since), as: UTF8.self)
        if text.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("[    0.") }) {
          return text
        }
        try await Task.sleep(for: .seconds(1))
      }
      return ""
    }
    let key = dir.appending(path: "id_ed25519")
    /// The guest's `/proc/cmdline`, over SSH.
    func procCommandLine(_ ip: String) async -> String {
      let result = await VZGuestSSH.poll(
        key: key, host: ip, command: "cat /proc/cmdline", within: .seconds(180))
      return result?.status == 0
        ? (result?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    func bootEvents() async throws -> [VMEvent] {
      try await EventLog(vmDirectory: dir).read().events.filter { $0.data?["commandLine"] != nil }
    }

    // The first boot: the kernel's own messages are on hvc0, and its command line ends with
    // console=hvc0. (Those printed before the virtio console driver loads, the banner and the
    // command line among them, never reach hvc0: VZ has no early console, and the kernel does
    // not replay them to it.)
    let config = try VZRunnerConfig.read(from: dir.appending(path: "vz-config.json"))
    guard case .linuxFromDisk(let kernel, _, let line) = config.boot else {
      Issue.record("the first boot did not boot the disk's kernel: \(config.boot)")
      return
    }
    #expect(kernel == dir.appending(path: "boot-cache/vmlinuz").path)
    #expect(line.hasSuffix("console=hvc0") && line.contains("root=PARTUUID="), "\(line)")
    let text = try await kernelOutput(since: 0)
    print("first boot transcript head:\n\(text.prefix(600))")
    #expect(!text.isEmpty, "no kernel messages on hvc0 during the first boot")
    let ip = try #require(started.runtime?.ip, "no DHCP lease for the guest's MAC")
    let cmdline = await procCommandLine(ip)
    #expect(cmdline == line, "the guest booted with \(cmdline)")
    var events = try await bootEvents()
    #expect(events.map { $0.data?["refreshed"] } == [.bool(true)])

    // The guest changes its boot the usual way (a GRUB drop-in and update-grub) and touches
    // its kernel; it shuts down cleanly so the file system is consistent on disk.
    let changed = await VZGuestSSH.poll(
      key: key, host: ip,
      command: "cloud-init status --wait >/dev/null; sudo sh -c '"
        + "echo GRUB_CMDLINE_LINUX_DEFAULT=\\\"\\$GRUB_CMDLINE_LINUX_DEFAULT vmlab.reread=1\\\" "
        + "> /etc/default/grub.d/99-vmlab-test.cfg && update-grub && "
        + "touch /boot/vmlinuz-$(uname -r) && sync' && grep -c vmlab.reread=1 /boot/grub/grub.cfg",
      within: .seconds(420))
    #expect(changed?.status == 0, "\(changed?.output ?? "ssh failed")")
    _ = try await context.manager.perform(.stop, on: created.id, timeout: .seconds(120))

    let size =
      (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: "console.log").path))?[
        .size] as? NSNumber
    let since = Double(size?.uint64Value ?? 0)
    let restarted = try await context.manager.runAdmitted(.start, on: created.id)
    events = try await bootEvents()
    #expect(events.count == 2)
    #expect(events.last?.data?["refreshed"] == .bool(true), "the boot cache was not refreshed")
    let reread = events.last?.data?["commandLine"]?.stringValue ?? ""
    #expect(reread.contains("vmlab.reread=1") && reread.hasSuffix("console=hvc0"), "\(reread)")
    #expect(!(try await kernelOutput(since: Int(since))).isEmpty)
    let secondIP = try #require(restarted.record?.runtime?.ip, "no lease on the second boot")
    #expect(await procCommandLine(secondIP) == reread)
    #expect(try await context.manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await context.manager.perform(.destroy, on: created.id) == nil)
  }
}
