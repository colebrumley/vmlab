import Foundation
import Synchronization
import Testing
import VMLabCore

@Suite struct SSHTests {
  static func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-ssh-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func argumentVector() {
    let dir = URL(filePath: "/v/vms/vm-abc")
    let target = SSHTarget(
      vm: "vm-abc", endpoint: SSHEndpoint(host: "127.0.0.1", port: 50022), user: "debian",
      vmDirectory: dir)
    #expect(
      target.arguments(remote: "uname -a") == [
        "-i", "/v/vms/vm-abc/id_ed25519",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=/v/vms/vm-abc/known_hosts",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "HostKeyAlias=vm-abc",
        "-o", "IdentitiesOnly=yes",
        "-o", "IdentityAgent=none",
        "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3",
        "-o", "LogLevel=ERROR",
        "-F", "/dev/null",
        "-T",
        "-p", "50022",
        "-l", "debian",
        "127.0.0.1",
        "--",
        "uname -a",
      ])
  }

  @Test func endpointFromRuntime() {
    #expect(SSHEndpoint(runtime: nil) == nil)
    #expect(SSHEndpoint(runtime: VMRuntime(pid: 1, controlSocket: "/c")) == nil)
    #expect(
      SSHEndpoint(runtime: VMRuntime(pid: 1, controlSocket: "/c", sshPort: 4022, ip: "10.0.0.2"))
        == SSHEndpoint(host: "127.0.0.1", port: 4022))
    #expect(
      SSHEndpoint(runtime: VMRuntime(pid: 1, controlSocket: "/c", ip: "192.168.64.5"))
        == SSHEndpoint(host: "192.168.64.5", port: 22))
  }

  @Test func loginUserComesFromTheImage() throws {
    let home = try Self.tempDir()
    let linux = VMRecord(
      id: "vm-a", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64), features: [],
      image: "ubuntu-24.04-arm64")
    #expect(SSHTarget.loginUser(of: linux, home: home) == "ubuntu")
    var unknown = linux
    unknown.image = nil
    #expect(SSHTarget.loginUser(of: unknown, home: home) == "root")
    unknown.guest = GuestSpec(os: .macos, arch: .arm64)
    #expect(SSHTarget.loginUser(of: unknown, home: home) == "admin")
  }

  @Test func keygenArgumentsAndGeneration() throws {
    let dir = try Self.tempDir()
    #expect(
      SSHKeys.keygenArguments(vmDirectory: dir, comment: "vmlab-vm-a") == [
        "-t", "ed25519", "-N", "", "-C", "vmlab-vm-a", "-f", dir.appending(path: "id_ed25519").path,
        "-q",
      ])
    let key = try SSHKeys.generate(in: dir, comment: "vmlab-vm-a")
    #expect(key.hasPrefix("ssh-ed25519 "))
    #expect(key.hasSuffix(" vmlab-vm-a"))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "id_ed25519").path))
    // A second call keeps the pair.
    #expect(try SSHKeys.generate(in: dir, comment: "other") == key)
  }

  @Test func keygenFailureIsProvisionFailed() throws {
    struct Failing: CommandRunning {
      func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
        CommandOutput(status: 1, output: "boom")
      }
    }
    let error = #expect(throws: VMLabError.self) {
      try SSHKeys.generate(in: try Self.tempDir(), comment: "x", runner: Failing())
    }
    #expect(error?.code == .provisionFailed)
  }

  @Test func bootTimeouts() {
    #expect(ResourceLimits.bootTimeout(profile: .qemuHVF, os: .linux) == .seconds(180))
    #expect(ResourceLimits.bootTimeout(profile: .vzMacOS, os: .macos) == .seconds(300))
    #expect(ResourceLimits.bootTimeout(profile: .qemuTCG, os: .linux) == .seconds(900))
  }

  /// A stand-in `ssh` that exits with the status in its environment, so readiness can be driven
  /// without a guest.
  @Test func readinessRetriesUntilSSHAnswers() async throws {
    let dir = try Self.tempDir()
    let counter = dir.appending(path: "count")
    let script = dir.appending(path: "ssh")
    try """
    #!/bin/sh
    n=$(cat '\(counter.path)' 2>/dev/null || echo 0)
    n=$((n+1)); echo $n > '\(counter.path)'
    [ $n -ge 3 ] && exit 0
    echo "ssh: connect to host 127.0.0.1 port 1: Connection refused" >&2; exit 255
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let target = SSHTarget(
      vm: "vm-a", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1), user: "u", vmDirectory: dir)
    let readiness = SSHReadiness(ssh: script.path, interval: .milliseconds(10))
    #expect(await readiness.wait(for: target, timeout: .seconds(20)) == nil)
    #expect(try String(contentsOf: counter, encoding: .utf8) == "3\n")
  }

  @Test func readinessGivesUpWithAWarning() async throws {
    let dir = try Self.tempDir()
    let target = SSHTarget(
      vm: "vm-a", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1), user: "u", vmDirectory: dir)
    let readiness = SSHReadiness(ssh: "/usr/bin/false", interval: .milliseconds(50))
    let warning = await readiness.wait(for: target, timeout: .milliseconds(300))
    #expect(warning?.hasPrefix("ssh_unreachable: vm-a") == true)
  }
}

/// Answers readiness with a fixed warning and records the targets it was asked about.
final class FakeReadiness: GuestReadiness {
  let warning: String?
  private let asked = Mutex<[SSHTarget]>([])
  private let limits = Mutex<[Duration]>([])
  var targets: [SSHTarget] { asked.withLock { $0 } }
  /// The timeout of every wait.
  var timeouts: [Duration] { limits.withLock { $0 } }

  init(warning: String? = nil) { self.warning = warning }

  func wait(for target: SSHTarget, timeout: Duration) async -> String? {
    asked.withLock { $0.append(target) }
    limits.withLock { $0.append(timeout) }
    return warning
  }
}
