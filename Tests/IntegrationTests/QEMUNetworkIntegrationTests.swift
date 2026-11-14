import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite struct QEMUNetworkIntegrationTests {
  /// Makes `<vm>/id_ed25519` unless the VM already has a key (R-400 makes one at create).
  static func ensureKey(_ directory: URL) throws {
    let key = directory.appending(path: "id_ed25519")
    guard !FileManager.default.fileExists(atPath: key.path) else { return }
    let keygen = Process()
    keygen.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "vmlab-test", "-f", key.path]
    try keygen.run()
    keygen.waitUntilExit()
    #expect(keygen.terminationStatus == 0)
  }

  /// `ssh -p <port> debian@127.0.0.1 <command>` with the VM's key; the exit status and stdout.
  /// ssh is waited for off the cooperative pool.
  static func ssh(_ key: URL, port: Int, _ command: String) async throws -> (Int32, String) {
    try await OffPool.run { () throws -> (Int32, String) in
      try sshBlocking(key, port: port, command)
    }
  }

  private static func sshBlocking(_ key: URL, port: Int, _ command: String) throws -> (
    Int32, String
  ) {
    let ssh = Process()
    ssh.executableURL = URL(filePath: "/usr/bin/ssh")
    ssh.arguments = [
      "-i", key.path, "-p", "\(port)", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR",
      "debian@127.0.0.1", command,
    ]
    let out = Pipe()
    ssh.standardOutput = out
    ssh.standardError = FileHandle.nullDevice
    ssh.standardInput = FileHandle.nullDevice
    try ssh.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    ssh.waitUntilExit()
    return (ssh.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// R-308 Verify (integration): `ssh -p <runtime.sshPort>` reaches the Debian guest with the
  /// generated key, and so does an ephemeral `net_port_forward` of guest port 22 (host 0).
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(4)))
  func sshReachesTheGuestThroughUserModeForwards() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .netNAT, .netPortForward], prepare: Self.ensureKey,
      network: NetworkSpec(mode: .nat, forwards: [PortForward(guest: 22)]))
    do {
      let runtime = try #require(guest.record.runtime)
      let sshPort = try #require(runtime.sshPort)
      let forwarded = try #require(runtime.forwards?.first?.host)
      #expect(forwarded != sshPort)
      #expect(
        try Store(home: guest.home).load(id: guest.record.id).runtime?.forwards == runtime.forwards)
      let key = guest.machine.layout.directory.appending(path: "id_ed25519")

      // cloud-init installs the key on first boot; retry until sshd accepts it.
      let deadline = ContinuousClock.now + .seconds(150)
      var result: (Int32, String) = (-1, "")
      while ContinuousClock.now < deadline {
        result = try await Self.ssh(key, port: sshPort, "echo vmlab-ok")
        if result.0 == 0 { break }
        try await Task.sleep(for: .seconds(3))
      }
      #expect(result.0 == 0 && result.1.contains("vmlab-ok"), "ssh via runtime.sshPort: \(result)")
      let viaForward = try await Self.ssh(key, port: forwarded, "hostname")
      #expect(viaForward.0 == 0, "ssh via the ephemeral forward \(forwarded)")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// A TCP listener on the Mac's loopback, as a dev server or a database would be; the kernel
  /// completes connections from its backlog, so nothing needs to accept.
  static func loopbackListener() throws -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    try #require(bound)
    return (fd, Int(UInt16(bigEndian: addr.sin_port)))
  }

  /// Boots a guest on `mode` and has it connect to `port` on 10.0.2.2, which user-mode
  /// networking maps to the Mac's loopback; `reached` or `blocked`.
  static func reachHostLoopback(_ mode: NetworkSpec.Mode, port: Int) async throws -> String {
    let guest = try await QEMUGuest.boot(
      features: [.serial, mode == .isolated ? .netIsolated : .netNAT], prepare: Self.ensureKey,
      network: NetworkSpec(mode: mode))
    do {
      #expect(guest.record.network.mode == mode)
      let sshPort = try #require(guest.record.runtime?.sshPort)
      let key = guest.machine.layout.directory.appending(path: "id_ed25519")
      let probe =
        "timeout 5 bash -c 'exec 3<>/dev/tcp/10.0.2.2/\(port)' 2>/dev/null "
        + "&& echo reached || echo blocked"
      let deadline = ContinuousClock.now + .seconds(150)
      var result: (Int32, String) = (-1, "")
      while ContinuousClock.now < deadline {
        result = try await Self.ssh(key, port: sshPort, probe)
        if result.0 == 0 { break }
        try await Task.sleep(for: .seconds(3))
      }
      #expect(result.0 == 0, "ssh to the \(mode.rawValue) guest: \(result)")
      await guest.shutdown()
      return result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      await guest.shutdown()
      throw error
    }
  }

  /// Verify (integration): an isolated guest answers SSH on its forward and cannot connect to a
  /// listener on the Mac's loopback; a NAT guest, the control, can.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(8)))
  func anIsolatedGuestCannotReachTheHostsLoopback() async throws {
    let listener = try Self.loopbackListener()
    defer { close(listener.fd) }
    #expect(try await Self.reachHostLoopback(.isolated, port: listener.port) == "blocked")
    #expect(try await Self.reachHostLoopback(.nat, port: listener.port) == "reached")
  }
}
