import Foundation
import Testing
import VMLabCore
import VMLabVZ

@testable import VMLabMCP

/// R-604 Verify (integration): the Debian kernel and initrd extracted from the pulled image
/// (`images extract_kernel`, R-305) boot through `VZLinuxBootLoader` to `login:` on serial.
@Suite(.serialized) struct VZKernelBootIntegrationTests {
  static let ready = VZRunnerIntegrationTests.ready

  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func extractedKernelBootsToLogin() async throws {
    // Short home: unix socket paths must stay under 104 bytes.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-k")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    // The shared image cache: the kernel is extracted there once, as R-305 does.
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    VZRunnerIntegrationTests.signRunner()

    let store = Store(home: home)
    let registry = BackendRegistry()
    registry.register(
      VZBackend(
        store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .seconds(1)))
    let context = ToolContext(home: home, backends: registry, startGate: IntegrationAdmission.gate)
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2),
      features: [.execSSH, .serial, .directKernelBoot], requested: [.directKernelBoot],
      estimatedStartupSeconds: 30)
    // No kernel path: the image's kernel, extracted on first use; the default command line.
    let created = try await context.manager.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64",
        boot: BootSpec(mode: .kernel)),
      plan: plan)
    let started = try #require(try await context.manager.performAdmitted(.start, on: created.id))
    defer {
      if let pid = try? store.load(id: created.id).runtime?.pid { kill(pid, SIGKILL) }
    }
    let config = try VZRunnerConfig.read(
      from: VZRunnerPaths(vmDirectory: store.directory(of: created.id)).config)
    guard case .linuxKernel(let kernel, let initrd, let line) = config.boot else {
      Issue.record("the runner was not given a kernel boot: \(config.boot)")
      return
    }
    #expect(kernel.hasSuffix("/kernel/vmlinuz") && initrd?.hasSuffix("/kernel/initrd.img") == true)
    #expect(line == VZRunnerConfig.defaultCommandLine)
    #expect(started.state == .running)

    let login = try await ToolHandlers.call(
      "vm_serial",
      arguments: .object([
        "vm": .string(created.id), "action": .string("wait"), "pattern": .string("login: "),
        "timeoutSeconds": .number(90),
      ]), context: context)
    #expect(login.value["matched"] == .string("login: "))
    // console=hvc0 from the first boot: kernel lines (from when the virtio console registered)
    // come before systemd and the prompt.
    let text = login.value["text"]?.stringValue ?? ""
    #expect(text.hasPrefix("[    0."), "no kernel output on hvc0")
    print("kernel boot transcript head:\n\(text.prefix(400))")

    #expect(try await context.manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await context.manager.perform(.destroy, on: created.id) == nil)
  }

  /// R-1202 Verify (integration): `image: "none"` on `vz-linux` with the extracted Debian kernel
  /// and initrd: no disk and no seed, the runner gets no storage device, and the kernel speaks on
  /// `hvc0`. VZ has no early console, so the banner (`Linux version`) comes before the virtio
  /// console registers and `hvc0` starts later; the kernel's `Run /init` line is on it. The initrd
  /// finds no root, as expected; the VM is killed.
  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func kernelWithoutImage() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-kn")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    VZRunnerIntegrationTests.signRunner()

    let store = Store(home: home)
    let registry = BackendRegistry()
    registry.register(
      VZBackend(
        store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .seconds(1)))
    let context = ToolContext(home: home, backends: registry, startGate: IntegrationAdmission.gate)
    let images = ImageStore(home: home)
    var files = images.kernel(of: "debian-13-arm64")
    if files == nil { files = try await images.extractKernel("debian-13-arm64") }
    let kernel = try #require(files)
    let requirements: JSONValue = .object([
      "guest": .object(["os": .string("linux"), "arch": .string("arm64")]),
      "require": .array([.string("serial")]),
      "resources": .object(["cpus": .number(2), "memoryGB": .number(2)]),
      "image": .string("none"),
      "boot": .object([
        "mode": .string("kernel"), "kernel": .string(kernel.kernel.path),
        "initrd": kernel.initrd.map { .string($0.path) } ?? .null,
      ]),
    ])
    let created = try await ToolHandlers.call(
      "vm_create",
      arguments: .object([
        "requirements": requirements, "name": .string("bare-vz"), "autostart": .bool(false),
      ]), context: context)
    #expect(created.value["plan"]?["profile"] == .string("vz-linux"), "\(created.value)")
    let id = try store.find("bare-vz").id
    let directory = store.directory(of: id)
    defer {
      if let pid = try? store.load(id: id).runtime?.pid { kill(pid, SIGKILL) }
    }
    let start = try await ToolHandlers.call(
      "vm_lifecycle", arguments: .object(["vm": .string(id), "action": .string("start")]),
      context: context)
    #expect(start.value["state"] == .string("running"))
    #expect(!start.warnings.contains { $0.contains("ssh_unreachable") })
    for file in ["disk.raw", "seed.iso", "id_ed25519"] {
      #expect(
        !FileManager.default.fileExists(atPath: directory.appending(path: file).path), "\(file)")
    }
    let config = try VZRunnerConfig.read(from: VZRunnerPaths(vmDirectory: directory).config)
    #expect(config.disks.isEmpty)

    let booted = try await ToolHandlers.call(
      "vm_serial",
      arguments: .object([
        "vm": .string(id), "action": .string("wait"),
        "pattern": .string("Linux version|Booting Linux|Run /init as init process"),
        "timeoutSeconds": .number(60),
      ]), context: context)
    #expect(booted.value["matched"]?.stringValue?.isEmpty == false, "\(booted.value)")

    #expect(try await context.manager.perform(.kill, on: id)?.state == .stopped)
    #expect(try await context.manager.perform(.destroy, on: id) == nil)
  }
}
