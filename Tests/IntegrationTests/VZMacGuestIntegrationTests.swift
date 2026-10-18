import Foundation
import Testing
import VMLabCore
import VMLabEngines
import VMLabRFB
import VMLabVZ

@testable import VMLabMCP

/// R-605 to R-607 Verify (integration): a `tart clone` of the pulled `macos-base` image boots in
/// our own runner. Needs `tart`, the image pulled into `~/.vmlab/images` (`vmlab images pull
/// macos-base`) and fewer than two macOS guests running on the host. Each test destroys its
/// clone in teardown.
@Suite(.serialized) struct VZMacGuestIntegrationTests {
  static let images = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".vmlab/images")
  static let pulled = ImageStore(home: images.deletingLastPathComponent()).pulled("macos-base")
  static let ready =
    integrationEnabled && pulled?.tartVM != nil && (try? Tart.locate()) != nil
    && FileManager.default.isExecutableFile(atPath: VZRunnerIntegrationTests.runner)

  /// A macOS guest made and started through `VMManager`, destroyed by `teardown`.
  struct Guest {
    let home: URL
    let store: Store
    let manager: VMManager
    let registry: BackendRegistry
    let record: VMRecord

    var directory: URL { store.directory(of: record.id) }

    func teardown() async {
      _ = try? await manager.perform(.kill, on: record.id)
      _ = try? await manager.perform(.destroy, on: record.id)
      if let clone = record.tartClone, FileManager.default.fileExists(atPath: clone) {
        _ = try? Tart.locate().delete(URL(filePath: clone).lastPathComponent)
      }
      try? FileManager.default.removeItem(at: home)
    }
  }

  /// Fewer than two macOS guests on the host (Apple's limit, shared by every session).
  static func hostHasRoom() -> Bool {
    let processes = ProcessRunner().run("/bin/ps", ["-Ao", "command"])?.output ?? ""
    var guests = 0
    for line in processes.split(separator: "\n") {
      if line.contains("tart run") { guests += 1 }
      // Any session's vmlab-vz runner of a macOS guest (its config boots `macOS`).
      guard let range = line.range(of: "vmlab-vz run ") else { continue }
      let vm = URL(
        filePath: String(line[range.upperBound...].split(separator: " ").first ?? ""))
      if let config = try? String(
        contentsOf: VZRunnerPaths(vmDirectory: vm).config, encoding: .utf8),
        config.contains("\"macOS\"")
      {
        guests += 1
      }
    }
    if guests >= 2 { print("skipping: \(guests) macOS guests already run on this host") }
    return guests < 2
  }

  static func makeGuest(
    features: [Feature], suffix: String, provision: ProvisionSpec? = nil,
    share: (URL) -> SharedDirSpec? = { _ in nil }
  ) async throws -> Guest {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-\(suffix)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"), withDestinationURL: images)
    try VZRunnerIntegrationTests.signRunner()
    let store = Store(home: home)
    let registry = BackendRegistry()
    registry.register(
      VZMacBackend(
        store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
        leaseTimeout: .seconds(240)))
    let manager = VMManager(store: store, backends: registry)
    let plan = Plan(
      profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      resources: ResourceSpec(cpus: 4, memoryGB: 8), features: features, requested: features,
      estimatedStartupSeconds: 60)
    let created = try await manager.create(
      VMRecord(
        id: "", profile: .vzMacOS, guest: plan.guest, features: [], image: "macos-base",
        provision: provision, share: share(home)),
      plan: plan)
    return Guest(
      home: home, store: store, manager: manager, registry: registry,
      record: try store.load(id: created.id))
  }

  /// R-605: the clone boots, its lease is found by the clone's MAC, and `ssh admin@<ip>` with the
  /// image password works.
  @Test(.enabled(if: ready && hostHasRoom()), .timeLimit(.minutes(10)))
  func clonedGuestBootsAndAcceptsPasswordSSH() async throws {
    let clock = ContinuousClock()
    let begun = clock.now
    let guest = try await Self.makeGuest(features: [.execSSH], suffix: "m")
    print("clone made after \(clock.now - begun)")
    do {
      let clone = try #require(guest.record.tartClone)
      #expect(clone.hasSuffix("/vms/\(guest.record.id)"))
      let config = try TartVMConfig.read(from: URL(filePath: clone))

      let started = try #require(
        try await guest.manager.performAdmitted(.start, on: guest.record.id))
      #expect(started.state == .running)
      let ip = try #require(started.runtime?.ip, "no DHCP lease for the clone's MAC")
      #expect(DHCPLeases.lookup(mac: MACAddress.normalize(config.macAddress) ?? "") == ip)
      print("lease \(ip) after \(clock.now - begun)")

      let login = try #require(Self.pulled?.login)
      let ssh = PasswordSSH(
        user: login.user, host: ip, password: login.password ?? "", scratch: guest.directory)
      var output: CommandOutput? = nil
      let deadline = clock.now.advanced(by: .seconds(240))
      while clock.now < deadline {
        output = await ssh.run("sw_vers -productVersion", timeout: .seconds(20))
        if output?.status == 0 { break }
        try await Task.sleep(for: .seconds(3))
      }
      #expect(output?.status == 0, "ssh failed: \(output?.output ?? "nothing")")
      print("ssh ok after \(clock.now - begun): \(output?.output ?? "")")
    } catch {
      await guest.teardown()
      throw error
    }
    await guest.teardown()
  }

  /// CX-27: `shared_dir` on a macOS guest: a file in the VM's `shared/` directory on the host is
  /// readable in the guest at /Volumes/My Shared Files (the automount tag), and one written there
  /// shows up on the host.
  @Test(.enabled(if: ready && hostHasRoom()), .timeLimit(.minutes(12)))
  func sharedDirIsAutomountedInTheGuest() async throws {
    let guest = try await Self.makeGuest(features: [.execSSH, .sharedDir], suffix: "s")
    do {
      let shared = guest.directory.appending(path: "shared", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
      try Data("from the host\n".utf8).write(to: shared.appending(path: "hello.txt"))
      let started = try #require(
        try await guest.manager.performAdmitted(.start, on: guest.record.id))
      let ip = try #require(started.runtime?.ip)
      let mount = SharedDirSpec.macOSAutomountPath
      var output: CommandOutput? = nil
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(120))
      while clock.now < deadline {
        output = Self.keySSH(guest, host: ip, command: "cat '\(mount)/hello.txt'")
        if output?.status == 0 { break }
        try await Task.sleep(for: .seconds(3))
      }
      #expect(output?.output.contains("from the host") == true, "\(output?.output ?? "nothing")")
      let wrote = Self.keySSH(guest, host: ip, command: "echo from the guest > '\(mount)/back.txt'")
      #expect(wrote?.status == 0, "\(wrote?.output ?? "nothing")")
      let back = try? String(contentsOf: shared.appending(path: "back.txt"), encoding: .utf8)
      #expect(back?.contains("from the guest") == true)
    } catch {
      await guest.teardown()
      throw error
    }
    await guest.teardown()
  }

  /// A share at a guest path of its own (/Users/admin/hostshare): first boot installs the
  /// io.vmlab.share LaunchDaemon with the image's sudo password; a host file is readable there, a
  /// guest write shows up on the host, and after a stop and start the mount is back.
  @Test(.enabled(if: ready && hostHasRoom()), .timeLimit(.minutes(15)))
  func shareAtAGuestPathOfItsOwnSurvivesARestart() async throws {
    let mount = "/Users/admin/hostshare"
    let guest = try await Self.makeGuest(
      features: [.execSSH, .sharedDir], suffix: "h",
      share: { home in
        let host = home.appending(path: "hostshare", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        return SharedDirSpec(host: host.path, guest: mount)
      })
    do {
      let host = URL(filePath: try #require(guest.record.share?.host))
      try Data("from the host\n".utf8).write(to: host.appending(path: "hello.txt"))
      let started = try #require(
        try await guest.manager.performAdmitted(.start, on: guest.record.id))
      let ip = try #require(started.runtime?.ip)
      let report = try #require(ProvisionReport.load(from: guest.directory))
      #expect(report.steps.allSatisfy { $0.status == .succeeded }, "\(report.steps)")
      #expect(report.steps.contains { $0.name == "share_mount" })
      let read = Self.keySSH(guest, host: ip, command: "cat '\(mount)/hello.txt'")
      #expect(read?.output.contains("from the host") == true, "\(read?.output ?? "nothing")")
      let wrote = Self.keySSH(guest, host: ip, command: "echo from the guest > '\(mount)/back.txt'")
      #expect(wrote?.status == 0, "\(wrote?.output ?? "nothing")")
      let back = try? String(contentsOf: host.appending(path: "back.txt"), encoding: .utf8)
      #expect(back?.contains("from the guest") == true)

      // A restart: the daemon mounts it again at boot (provisioning does not run twice).
      _ = try await guest.manager.perform(.stop, on: guest.record.id)
      try Data("after the restart\n".utf8).write(to: host.appending(path: "again.txt"))
      let again = try #require(
        try await guest.manager.performAdmitted(.start, on: guest.record.id))
      let ip2 = try #require(again.runtime?.ip)
      var output: CommandOutput? = nil
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(180))
      while clock.now < deadline {
        output = Self.keySSH(guest, host: ip2, command: "cat '\(mount)/again.txt'")
        if output?.status == 0 { break }
        try await Task.sleep(for: .seconds(3))
      }
      #expect(output?.output.contains("after the restart") == true, "\(output?.output ?? "")")
      let mounts = Self.keySSH(guest, host: ip2, command: "/sbin/mount")
      #expect(mounts?.output.contains(" on \(mount) (") == true, "\(mounts?.output ?? "")")
    } catch {
      await guest.teardown()
      throw error
    }
    await guest.teardown()
  }

  static func point(_ x: Int, _ y: Int) -> JSONValue {
    .array([.number(Double(x)), .number(Double(y))])
  }

  static func keySSH(_ guest: Guest, host: String, command: String) -> CommandOutput? {
    ProcessRunner().run(
      "/usr/bin/ssh",
      [
        "-i", guest.directory.appending(path: "id_ed25519").path, "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR",
        "admin@\(host)", command,
      ])
  }

  /// A framebuffer is blank when every pixel is the same colour.
  static func distinctColours(_ framebuffer: Framebuffer) -> Int {
    var seen = Set<UInt32>()
    let pixels = framebuffer.pixels
    var index = 0
    while index + 3 < pixels.count, seen.count < 64 {
      seen.insert(
        UInt32(pixels[index]) | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]) << 16)
      index += 4 * 97
    }
    return seen.count
  }

  /// R-606: after create (with `gui`), the first start provisions the guest: `sw_vers` runs with
  /// the VM's own key, and a screenshot through Screen Sharing with `<vm>/vnc.pass` is non-blank.
  @Test(.enabled(if: ready && hostHasRoom()), .timeLimit(.minutes(12)))
  func provisionedGuestTakesTheKeyAndShowsItsScreen() async throws {
    let clock = ContinuousClock()
    let begun = clock.now
    let guest = try await Self.makeGuest(features: [.execSSH, .gui, .guiDesktop], suffix: "p")
    do {
      let started = try #require(
        try await guest.manager.performAdmitted(.start, on: guest.record.id))
      print("started and provisioned after \(clock.now - begun)")
      #expect(MacProvisioner.isProvisioned(guest.directory))
      let ip = try #require(started.runtime?.ip)
      let version = Self.keySSH(guest, host: ip, command: "sw_vers")
      #expect(version?.status == 0, "key ssh failed: \(version?.output ?? "nothing")")
      #expect(version?.output.contains("ProductVersion") == true)

      let password = try String(
        contentsOf: guest.directory.appending(path: "vnc.pass"), encoding: .utf8)
      let client = try await RFBClient.connect(.tcp(host: ip, port: 5900), password: password)
      await client.start()
      try await client.waitForUpdate(timeout: .seconds(30))
      try await Task.sleep(for: .seconds(2))
      let colours = Self.distinctColours(await client.framebuffer)
      let png = try await client.framebuffer.pngData()
      try png.write(
        to: URL(filePath: NSTemporaryDirectory()).appending(path: "vmlab-macos-r606.png"))
      await client.close()
      #expect(colours > 4, "the Screen Sharing frame is blank (\(colours) colours)")
    } catch {
      await guest.teardown()
      throw error
    }
    await guest.teardown()
  }

  /// R-607: `vm_computer` drives the guest's Screen Sharing end to end: `key cmd+space` (noted as
  /// Super_L), `type "Terminal"`, `key Return`, and the screen then shows a new window (the
  /// bounding box of the change against the screenshot before is non-empty and window-sized).
  @Test(.enabled(if: ready && hostHasRoom()), .timeLimit(.minutes(12)))
  func vmComputerOpensTerminalThroughSpotlight() async throws {
    let guest = try await Self.makeGuest(features: [.execSSH, .gui, .guiDesktop], suffix: "g")
    do {
      let started = try #require(
        try await guest.manager.performAdmitted(.start, on: guest.record.id))
      let ip = try #require(started.runtime?.ip)
      // The image restores a Terminal window at login; quit it so the new one is new.
      _ = Self.keySSH(guest, host: ip, command: "pkill -x Terminal")
      try await Task.sleep(for: .seconds(5))

      var context = ToolContext(
        home: guest.home,
        displays: DisplaySessions(connectors: DisplayConnectorRegistry(RFBDisplayConnector())))
      context.progress = .none
      func computer(_ arguments: [String: JSONValue]) async throws -> ToolResult {
        var arguments = arguments
        arguments["vm"] = .string(guest.record.id)
        return try await ToolHandlers.call(
          "vm_computer", arguments: .object(arguments), context: context)
      }
      let debug = ProcessInfo.processInfo.environment["VMLAB_DEBUG_DIR"].map { URL(filePath: $0) }
      func save(_ result: ToolResult, _ name: String) {
        if let debug, let image = result.images.first {
          try? image.data.write(to: debug.appending(path: name))
        }
      }

      let before = try await computer(["action": .string("screenshot")])
      save(before, "macos-0-before.png")
      #expect(before.images.count == 1)
      let spotlight = try await computer([
        "action": .string("key"), "text": .string("cmd+space"), "settleMs": .number(1500),
      ])
      save(spotlight, "macos-1-spotlight.png")
      #expect(spotlight.warnings.contains(Computer.commandNote))
      // A fresh image greets the first Spotlight with an introduction that takes the keyboard
      // until its Continue button is clicked. Click where it sits, close Spotlight, and open it
      // again (without the introduction the click just lands on the desktop).
      _ = try await computer([
        "action": .string("left_click"), "coordinate": Self.point(512, 490),
        "settleMs": .number(1500),
      ])
      _ = try await computer([
        "action": .string("key"), "text": .string("Escape"), "settleMs": .number(1000),
      ])
      let again = try await computer([
        "action": .string("key"), "text": .string("cmd+space"), "settleMs": .number(1500),
      ])
      save(again, "macos-1b-spotlight.png")
      let typed = try await computer([
        "action": .string("type"), "text": .string("Terminal"), "settleMs": .number(1500),
      ])
      save(typed, "macos-2-typed.png")
      let opened = try await computer([
        "action": .string("key"), "text": .string("Return"), "settleMs": .number(5000),
      ])
      save(opened, "macos-3-opened.png")

      let diff = try await computer([
        "action": .string("screenshot"), "diffFrom": before.value["id"] ?? .null,
      ])
      save(diff, "macos-4-diff.png")
      #expect(diff.value["unchanged"] == .bool(false))
      let region = try #require(diff.value["changedRegion"])
      let width = region["width"]?.numberValue ?? 0
      let height = region["height"]?.numberValue ?? 0
      #expect(width > 200 && height > 150, "changed region \(region)")
      // And the guest agrees: Terminal runs again, as the frontmost app.
      let front = Self.keySSH(
        guest, host: ip, command: "lsappinfo info -only name `lsappinfo front`")
      #expect(front?.output.contains("Terminal") == true, "front app: \(front?.output ?? "none")")
    } catch {
      await guest.teardown()
      throw error
    }
    await guest.teardown()
  }
}
