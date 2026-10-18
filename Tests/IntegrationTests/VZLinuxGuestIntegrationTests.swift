import CoreGraphics
import Foundation
import ImageIO
import Testing
import VMLabCore
import VMLabEngines
import VMLabVZ

@testable import VMLabMCP

/// R-601 Verify (integration): the full VZ Linux configuration boots `debian-13-arm64` (raw) to
/// `login:` on the virtio console within 60 s, and the VM's own key logs in over SSH at the address
/// read from vmnet's lease file.
@Suite(.serialized) struct VZLinuxGuestIntegrationTests {
  static let ready = VZRunnerIntegrationTests.ready

  static func waitFor(_ text: String, in file: URL, within limit: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
      if let data = try? Data(contentsOf: file),
        String(decoding: data, as: UTF8.self).contains(text)
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return false
  }

  static func ssh(key: URL, user: String, host: String, command: String) -> CommandOutput? {
    ProcessRunner().run(
      "/usr/bin/ssh",
      [
        "-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "\(user)@\(host)", command,
      ])
  }

  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func bootsToLoginOnSerialAndAcceptsSSH() async throws {
    // Short home: unix socket paths must stay under 104 bytes.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-l")
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
        leaseTimeout: .seconds(90)))
    let manager = VMManager(store: store, backends: registry)
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2), features: [.execSSH, .serial],
      estimatedStartupSeconds: 30)
    let created = try await manager.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64"),
      plan: plan)
    let dir = store.directory(of: created.id)
    let console = dir.appending(path: "console.log")

    let clock = ContinuousClock()
    let begun = clock.now
    // The login prompt is watched while start waits for the lease.
    async let sawLogin = Self.waitFor("login:", in: console, within: .seconds(60))
    let started = try #require(try await manager.performAdmitted(.start, on: created.id))
    defer {
      if let pid = started.runtime?.pid { kill(pid, SIGKILL) }
    }
    #expect(started.state == .running)
    #expect(await sawLogin, "no login: on the virtio console within 60 s")
    print("login: after \(clock.now - begun)")

    let ip = try #require(started.runtime?.ip, "no DHCP lease for the guest's MAC")
    #expect(try store.load(id: created.id).runtime?.ip == ip)
    #expect(
      DHCPLeases.lookup(mac: VZRunnerConfig.stableMAC(for: created.id)) == ip)

    // cloud-init installs the key early in boot; retry until sshd takes it.
    var output: CommandOutput? = nil
    let deadline = clock.now.advanced(by: .seconds(120))
    while clock.now < deadline {
      output = Self.ssh(
        key: dir.appending(path: "id_ed25519"), user: "debian", host: ip, command: "hostname")
      if output?.status == 0 { break }
      try await Task.sleep(for: .seconds(2))
    }
    #expect(output?.status == 0, "ssh failed: \(output?.output ?? "nothing")")
    print("ssh ok after \(clock.now - begun): \(output?.output ?? "")")

    #expect(try await manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await manager.perform(.destroy, on: created.id) == nil)
  }

  /// Lit pixels and distinct colours (sampled) of an RGBA-decoded PNG, or nil if it does not decode.
  static func pixelStats(png: Data) -> (width: Int, height: Int, lit: Double, colours: Int)? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    var lit = 0
    var colours = Set<UInt32>()
    var i = 0
    while i < pixels.count {
      let (r, g, b) = (pixels[i], pixels[i + 1], pixels[i + 2])
      if r > 40 || g > 40 || b > 40 { lit += 1 }
      if (i / 4) % 7 == 0 { colours.insert(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)) }
      i += 4
    }
    return (width, height, Double(lit) / Double(max(1, width * height)), colours.count)
  }

  /// The `gui` sentence: with `gui` required, a screenshot through the in-guest VNC server (R-504
  /// provisioning: Xfce, LightDM autologin, x11vnc on the NIC) shows a desktop. First boot
  /// installs the packages, so the desktop may take up to 10 minutes, as in R-504's Verify.
  @Test(.enabled(if: ready), .timeLimit(.minutes(20)))
  func guiGuestShowsADesktop() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-g")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    VZRunnerIntegrationTests.signRunner()

    let registry = BackendRegistry()
    registry.register(
      VZBackend(
        store: Store(home: home),
        launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .seconds(90)))
    var context = ToolContext(
      home: home, backends: registry,
      displays: DisplaySessions(connectors: DisplayConnectorRegistry(RFBDisplayConnector())))
    context.progress = .none
    let manager = context.manager
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 4, diskGB: 12),
      features: [.execSSH, .serial, .gui, .netNAT], requested: [.gui],
      estimatedStartupSeconds: 30 + Plan.desktopInstallSeconds)
    #expect(plan.provisionsDesktop)
    let created = try await manager.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64"),
      plan: plan)
    let dir = context.store.directory(of: created.id)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "vnc.pass").path))

    let started = try #require(try await manager.perform(.start, on: created.id))
    defer {
      if let pid = started.runtime?.pid { kill(pid, SIGKILL) }
    }
    #expect(started.state == .running)

    func screenshot() async throws -> ToolResult {
      try await ToolHandlers.call(
        "vm_computer",
        arguments: .object(["vm": .string(created.id), "action": .string("screenshot")]),
        context: context)
    }

    // Poll vm_computer until the in-guest VNC server answers with a lit, many-coloured frame.
    let clock = ContinuousClock()
    let begun = clock.now
    var last = "no screenshot"
    var shown: (width: Int, height: Int, lit: Double, colours: Int)? = nil
    var shot = 0
    while clock.now - begun < .seconds(600) {
      do {
        let result = try await screenshot()
        if let png = result.images.first?.data, let stats = Self.pixelStats(png: png) {
          last = "\(stats.width)x\(stats.height) lit \(stats.lit) colours \(stats.colours)"
          if let debug = GUIDesktopIntegrationTests.debugDir() {
            shot += 1
            try? png.write(to: debug.appending(path: "vz-gui-\(shot).png"))
          }
          if stats.lit > 0.5 && stats.colours > 16 {
            shown = stats
            break
          }
        }
      } catch {
        last = "\(error)"
      }
      try await Task.sleep(for: .seconds(10))
    }
    print("vz gui after \(clock.now - begun): \(last)")
    if shown == nil, let ip = try context.store.load(id: created.id).runtime?.ip {
      let state = Self.ssh(
        key: dir.appending(path: "id_ed25519"), user: "debian", host: ip,
        command: "cloud-init status --long; systemctl --no-pager status lightdm vmlab-vnc; "
          + "sudo tail -n 30 /var/log/Xorg.0.log")
      Issue.record("guest state:\n\(state?.output ?? "ssh failed")")
    }
    let stats = try #require(shown, "no desktop within 10 minutes; last: \(last)")
    #expect(stats.width == 1280 && stats.height == 800)

    #expect(try await manager.perform(.kill, on: created.id)?.state == .stopped)
    #expect(try await manager.perform(.destroy, on: created.id) == nil)
  }
}
