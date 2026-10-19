import Foundation
import Synchronization
import Testing
import VMLabCore

@testable import VMLabVZ

@Suite struct MacProvisioningTests {
  /// Records each remote command and answers from `status`.
  final class FakeGuest: Sendable {
    let calls = Mutex<[(command: String, input: String)]>([])
    let status: @Sendable (String) -> Int32

    init(status: @escaping @Sendable (String) -> Int32 = { _ in 0 }) { self.status = status }

    var ssh: @Sendable (PasswordSSH, String, Data) async -> CommandOutput? {
      { session, command, input in
        self.calls.withLock { $0.append((command, String(decoding: input, as: UTF8.self))) }
        #expect(session.user == "admin" && session.host == "192.168.64.20")
        return CommandOutput(status: self.status(command), output: "")
      }
    }
  }

  static func provisioner(_ dir: URL, guest: FakeGuest, vnc: String?, rfb: Bool = true)
    -> MacProvisioner
  {
    MacProvisioner(
      vmDirectory: dir, login: ImageLogin(user: "admin", password: "admin"), hostname: "mac-1",
      publicKey: "ssh-ed25519 AAAA vmlab-vm-abc123", vncPassword: vnc, sshTimeout: .zero,
      ssh: guest.ssh, rfbProbe: { _, _, _ in rfb })
  }

  static func directory() throws -> URL {
    let dir = TartTests.temporary()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func installsKeySetsHostnameAndScreenSharing() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let guest = FakeGuest()
    try await Self.provisioner(dir, guest: guest, vnc: "abcd2345").provision(ip: "192.168.64.20")
    let calls = guest.calls.withLock { $0 }
    #expect(calls.count == 4)
    #expect(calls[0].command == "true")
    #expect(calls[1].command.contains("~/.ssh/authorized_keys"))
    #expect(calls[1].input == "ssh-ed25519 AAAA vmlab-vm-abc123\n")
    #expect(calls[2].command.contains("scutil --set HostName mac-1"))
    #expect(calls[2].input == "admin\n")
    #expect(calls[3].command.contains("-setvnclegacy -vnclegacy yes -setvncpw -vncpw abcd2345"))
    #expect(calls[3].command.contains("com.apple.screensharing"))
    #expect(MacProvisioner.isProvisioned(dir))
    // R-1004: the steps are in provision.json, the VNC password is not.
    let report = try #require(ProvisionReport.load(from: dir))
    #expect(report.steps.map(\.name) == ["ssh", "authorized_keys", "hostname", "screen_sharing"])
    #expect(report.steps.allSatisfy { $0.status == .succeeded })
    #expect(report.failure == nil && !report.hasRequestedSteps)
    #expect(report.steps[3].command.contains("-vncpw <vnc.pass>"))
    #expect(!report.steps.contains { $0.command.contains("abcd2345") })
    let log = try String(contentsOf: dir.appending(path: "provision.log"), encoding: .utf8)
    #expect(log.contains("provisioned"))
    #expect(!log.contains("admin\n"))
  }

  @Test func noScreenSharingWithoutGUI() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let guest = FakeGuest()
    try await Self.provisioner(dir, guest: guest, vnc: nil, rfb: false).provision(
      ip: "192.168.64.20")
    #expect(guest.calls.withLock { $0.map(\.command) }.allSatisfy { !$0.contains("kickstart") })
    #expect(MacProvisioner.isProvisioned(dir))
  }

  @Test func failuresNameTheStep() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let noSSH = await #expect(throws: VMLabError.self) {
      try await Self.provisioner(dir, guest: FakeGuest { _ in 255 }, vnc: nil)
        .provision(ip: "192.168.64.20")
    }
    #expect(noSSH?.code == .provisionFailed)
    #expect(noSSH?.data["step"] == .string("ssh"))
    #expect(ProvisionReport.load(from: dir)?.steps.map(\.status) == [.failed, .skipped, .skipped])

    let badHost = await #expect(throws: VMLabError.self) {
      try await Self.provisioner(
        dir, guest: FakeGuest { $0.contains("scutil") ? 1 : 0 }, vnc: nil
      ).provision(ip: "192.168.64.20")
    }
    #expect(badHost?.data["step"] == .string("hostname"))
    let failed = try #require(ProvisionReport.load(from: dir))
    #expect(failed.steps.map(\.status) == [.succeeded, .succeeded, .failed])
    #expect(failed.failure?.name == "hostname" && failed.failure?.exitCode == 1)
    #expect(
      failed.warning(vmDirectory: dir)?.hasPrefix(
        "provision_failed: \(dir.lastPathComponent) step hostname")
        == true)

    let noRFB = await #expect(throws: VMLabError.self) {
      try await Self.provisioner(dir, guest: FakeGuest(), vnc: "abcd2345", rfb: false)
        .provision(ip: "192.168.64.20")
    }
    #expect(noRFB?.data["step"] == .string("screen_sharing"))
    #expect(ProvisionReport.load(from: dir)?.failure?.error == "port 5900 did not answer RFB")
    #expect(!MacProvisioner.isProvisioned(dir))
  }

  @Test func vncPasswordIsMadeOnceAndPrivate() throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = try MacProvisioner.ensureVNCPassword(in: dir)
    #expect(first.count == 8 && first.allSatisfy { $0.isLetter || $0.isNumber })
    #expect(try MacProvisioner.ensureVNCPassword(in: dir) == first)
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: dir.appending(path: "vnc.pass").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }
}

extension MacProvisioningTests {
  /// R-901: a segment member's provisioning writes the networksetup script, then runs it as root
  /// with the segment NIC's MAC, address and mask; both steps are in provision.json.
  @Test func segmentMemberGetsAStaticAddress() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let guest = FakeGuest()
    var provisioner = Self.provisioner(dir, guest: guest, vnc: nil)
    provisioner.segment = SegmentAttachment(
      segment: "lab", address: "10.1.0.11", mac: "52:54:5e:0a:0b:0c")
    try await provisioner.provision(ip: "192.168.64.20")
    let calls = guest.calls.withLock { $0 }
    #expect(
      calls.map(\.command).last
        == "sudo -S -p '' /bin/sh /tmp/vmlab-segment.sh 52:54:5e:0a:0b:0c 10.1.0.11 255.255.255.0")
    #expect(calls.last?.input == "admin\n")
    #expect(calls.dropLast().last?.input.contains("networksetup -setmanual") == true)
    let report = try #require(ProvisionReport.load(from: dir))
    #expect(Array(report.steps.map(\.name).suffix(2)) == ["segment_script", "segment_address"])
    #expect(MacProvisioner.netmask(16) == "255.255.0.0")
  }

  /// The script's awk finds the service of a device in `networksetup -listnetworkserviceorder`.
  @Test func segmentScriptFindsTheServiceOfADevice() async throws {
    let script = MacProvisioner.segmentScript
    let line = try #require(
      script.split(separator: "\n").first { $0.contains("listnetworkserviceorder") })
    let program = try #require(
      line.split(separator: "'", omittingEmptySubsequences: false).dropFirst().first)
    let sample = """
      An asterisk (*) denotes that a network service is disabled.
      (1) Ethernet
      (Hardware Port: Ethernet, Device: en0)

      (2) Ethernet 2
      (Hardware Port: Ethernet, Device: en1)

      """
    let output = try await TestProcess.run(
      "/usr/bin/awk", ["-v", "d=en1", String(program)], stdin: Data(sample.utf8)
    ).output
    let text = String(decoding: output, as: UTF8.self)
    #expect(text == "Ethernet 2\n")
  }
}

extension MacProvisioningTests {
  static let awkwardPath = #"/Users/admin/it's a "share" & <more>"#

  /// A share off the automount path: check mount_virtiofs, stage the plist, install and
  /// bootstrap io.vmlab.share with sudo (the password on stdin only), wait for the mount; all in
  /// provision.json with the given sudo password nowhere in a command.
  @Test func shareElsewhereInstallsTheLaunchDaemon() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let guest = FakeGuest()
    var provisioner = Self.provisioner(dir, guest: guest, vnc: nil)
    provisioner.sharePath = Self.awkwardPath
    provisioner.sudoPassword = "sudo-s3cret"
    try await provisioner.provision(ip: "192.168.64.20")
    let calls = guest.calls.withLock { $0 }
    let names = try #require(ProvisionReport.load(from: dir)).steps.map(\.name)
    #expect(
      names == [
        "ssh", "authorized_keys", "hostname", "share_check", "share_plist", "share_daemon",
        "share_mount",
      ])
    #expect(calls.contains { $0.command == "test -x /sbin/mount_virtiofs" })
    let plist = try #require(calls.first { $0.command.contains("cat > /tmp/io.vmlab.share.plist") })
    #expect(plist.input == MacProvisioner.sharePlist(path: Self.awkwardPath))
    let daemon = try #require(calls.first { $0.command.contains("launchctl bootstrap") })
    #expect(daemon.command.hasPrefix("sudo -S -p '' "))
    #expect(daemon.command.contains(MacProvisioner.shareDaemonPath))
    #expect(daemon.input == "sudo-s3cret\n")
    // Every sudo step takes the given password, not the image's.
    #expect(
      calls.filter { $0.command.hasPrefix("sudo") }.allSatisfy { $0.input == "sudo-s3cret\n" })
    #expect(!calls.contains { $0.command.contains("sudo-s3cret") })
    let report = try String(contentsOf: ProvisionReport.url(in: dir), encoding: .utf8)
    #expect(!report.contains("sudo-s3cret"))
    #expect(MacProvisioner.isProvisioned(dir))
  }

  /// The plist parses, and its ProgramArguments carry the path verbatim (an argument, never shell
  /// text); the share_mount command quotes it as one shell word.
  @Test func sharePathsAreQuotedNotInterpreted() async throws {
    let data = Data(MacProvisioner.sharePlist(path: Self.awkwardPath).utf8)
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == "io.vmlab.share")
    #expect(plist["RunAtLoad"] as? Bool == true)
    let arguments = try #require(plist["ProgramArguments"] as? [String])
    #expect(
      arguments == ["/bin/sh", "-c", MacProvisioner.shareScript, Self.awkwardPath, "vmlab-share0"])
    for path in [Self.awkwardPath, "/a b/'c'", "/$(touch /tmp/x)`id`"] {
      let echoed = await ProcessRunner().run(
        "/bin/sh", ["-c", "printf %s " + MacProvisioner.shellQuote(path)])
      #expect(echoed?.output == path)
    }
    var provisioner = Self.provisioner(TartTests.temporary(), guest: FakeGuest(), vnc: nil)
    provisioner.sharePath = Self.awkwardPath
    let mount = try #require(provisioner.steps().first { $0.name == "share_mount" })
    #expect(mount.command.hasSuffix(" " + MacProvisioner.shellQuote(Self.awkwardPath)))
    // Both scripts parse, and share_mount finds a mount `mount` lists (here the host's own /).
    #expect(
      await ProcessRunner().run("/bin/sh", ["-n", "-c", MacProvisioner.shareScript])?.status == 0)
    provisioner.sharePath = "/"
    let root = try #require(provisioner.steps().first { $0.name == "share_mount" })
    #expect(await ProcessRunner().run("/bin/sh", ["-c", root.command])?.status == 0)
    // The automount path, or no share, needs no steps.
    provisioner.sharePath = nil
    #expect(!provisioner.steps().contains { $0.name.hasPrefix("share_") })
  }

  /// No mount_virtiofs in the guest: provisioning fails at share_check with a reason saying so.
  @Test func missingMountVirtiofsFailsAtShareCheck() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var provisioner = Self.provisioner(
      dir, guest: FakeGuest { $0.contains("mount_virtiofs") ? 1 : 0 }, vnc: nil)
    provisioner.sharePath = "/Users/admin/hostshare"
    let error = await #expect(throws: VMLabError.self) {
      try await provisioner.provision(ip: "192.168.64.20")
    }
    #expect(error?.data["step"] == .string("share_check"))
    #expect(error?.message.contains("/sbin/mount_virtiofs") == true)
    let report = try #require(ProvisionReport.load(from: dir))
    #expect(report.failure?.name == "share_check")
    #expect(report.steps.suffix(3).map(\.status) == [.skipped, .skipped, .skipped])
  }

  /// The given sudo password is redacted from a recorded command, like the VNC password.
  @Test func recordedCommandsRedactTheSudoPassword() {
    var provisioner = Self.provisioner(TartTests.temporary(), guest: FakeGuest(), vnc: "abcd2345")
    provisioner.sudoPassword = "hunter22"
    #expect(provisioner.recorded("x hunter22 abcd2345") == "x <sudo.pass> <vnc.pass>")
  }
}
