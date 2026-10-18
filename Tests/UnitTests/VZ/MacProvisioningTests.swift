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
