import Foundation
import Testing
import VMLabCore

/// `SSHExecChannel` against a stand-in `ssh` that runs the remote command with the local
/// `/bin/sh`, so the real remote scripts (process group, timeout kill, truncation) run on the host.
@Suite struct SSHExecTests {
  struct Fixture {
    let dir: URL
    let channel: SSHExecChannel

    init() throws {
      dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-exec-\(UUID())")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let ssh = dir.appending(path: "ssh")
      try """
      #!/bin/sh
      for a; do last=$a; done
      exec /bin/sh -c "$last"
      """.write(to: ssh, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
      let target = SSHTarget(
        vm: "vm-t", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1),
        user: NSUserName(), vmDirectory: dir)
      channel = SSHExecChannel(target: target, ssh: ssh.path)
    }

    func scratch() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "exec").path)
    }
  }

  @Test func exitCodeAndSeparateStreams() async throws {
    let f = try Fixture()
    let result = try await f.channel.run(
      ExecRequest(command: "echo out; echo err >&2; exit 3"))
    #expect(result.exitCode == 3)
    #expect(result.stdout == "out\n")
    #expect(result.stderr == "err\n")
    #expect(!result.truncated)
    #expect(result.logPath == nil)
    #expect(try f.scratch().isEmpty)
  }

  @Test func cwdEnvAndStdin() async throws {
    let f = try Fixture()
    let result = try await f.channel.run(
      ExecRequest(
        command: "pwd; echo \"$GREETING\"; cat", stdin: Data("from stdin\n".utf8), cwd: "/tmp",
        env: ["GREETING": "it's here"]))
    #expect(result.exitCode == 0)
    #expect(result.stdout.hasSuffix("tmp\nit's here\nfrom stdin\n"), "\(result.stdout)")
  }

  /// R-403: an `ssh` that never connected says so (`connected: false`), so `via: auto` may take
  /// the agent; one that dropped mid-command does not.
  @Test(arguments: [
    ("ssh: connect to host 127.0.0.1 port 1: Connection refused", false),
    ("kex_exchange_identification: read: Connection reset by peer", false),
    ("Connection closed by 127.0.0.1 port 2222", false),
    ("Connection reset by 127.0.0.1 port 2222", true),
    ("client_loop: send disconnect: Broken pipe", true),
  ])
  func unreachableSaysWhetherItConnected(stderr: String, connected: Bool) async throws {
    let f = try Fixture()
    let ssh = f.dir.appending(path: "ssh-fails")
    try "#!/bin/sh\necho '\(stderr)' >&2\nexit 255\n".write(
      to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    let channel = SSHExecChannel(target: f.channel.target, ssh: ssh.path)
    let error = await #expect(throws: VMLabError.self) {
      try await channel.run(ExecRequest(command: "true"))
    }
    #expect(error?.code == .guestUnreachable)
    #expect(error?.data[ExecFallback.connectedKey] == .bool(connected), "\(stderr)")
  }

  @Test func missingCwdExits126() async throws {
    let f = try Fixture()
    let result = try await f.channel.run(ExecRequest(command: "true", cwd: "/no/such/dir"))
    #expect(result.exitCode == 126)
  }

  @Test func largeOutputIsCutAndLogged() async throws {
    let f = try Fixture()
    // 200 KB of numbered lines.
    let result = try await f.channel.run(
      ExecRequest(command: "i=0; while [ $i -lt 20000 ]; do printf '%09d\\n' $i; i=$((i+1)); done"))
    #expect(result.exitCode == 0)
    #expect(result.truncated)
    #expect(result.stdout.hasPrefix("000000000\n"))
    #expect(result.stdout.hasSuffix("000019999\n"))
    #expect(result.stdout.contains("bytes omitted"))
    #expect(result.stdout.utf8.count < ExecOutput.inlineLimit + 100)
    let log = try #require(result.logPath)
    #expect(log.hasSuffix(".log"))
    #expect(try Data(contentsOf: URL(filePath: log)).count == 200_000)
    #expect(try f.scratch() == [URL(filePath: log).lastPathComponent])
  }

  @Test func timeoutKillsTheProcessGroupAndKeepsPartialOutput() async throws {
    let f = try Fixture()
    let marker = f.dir.appending(path: "child-alive")
    let started = ContinuousClock.now
    // The deadline leaves a loaded host time to start the shells and print `begun`; the
    // background child touches the marker every second for as long as it lives.
    let error = await #expect(throws: VMLabError.self) {
      try await f.channel.run(
        ExecRequest(
          command:
            "echo begun; (while :; do touch '\(marker.path)'; sleep 1; done) & sleep 300",
          timeout: .seconds(10)))
    }
    #expect(ContinuousClock.now - started < .seconds(60))
    #expect(error?.code == .timeout)
    #expect(error?.data["stdout"] == .string("begun\n"))
    #expect(error?.data["timeoutSeconds"] == .number(10))
    #expect(FileManager.default.fileExists(atPath: marker.path), "the child never ran")
    // The background child was in the group too: once killed, it touches nothing again.
    try FileManager.default.removeItem(at: marker)
    try await Task.sleep(for: .seconds(3))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  /// The race of a slow guest: ssh times out before the remote shell has written its process
  /// group id. The kill leaves a cancel mark, so the command never runs when the shell gets there.
  @Test func aTimeoutBeforeTheGroupStartsStillKillsIt() async throws {
    let f = try Fixture()
    // A "remote" that starts 2 s late, in its own process group (ending the local ssh does not
    // end it, as on a real guest); the kill connection runs at once.
    let slow = f.dir.appending(path: "ssh-slow")
    try """
    #!/bin/sh
    for a; do last=$a; done
    case "$last" in
      *'rc=$?'*)
        perl -e 'setpgrp(0, 0); exec @ARGV' /bin/sh -c 'sleep 2; exec /bin/sh -c "$1"' x "$last" &
        wait ;;
      *) exec /bin/sh -c "$last" ;;
    esac
    """.write(to: slow, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
    let channel = SSHExecChannel(target: f.channel.target, ssh: slow.path)
    let marker = f.dir.appending(path: "late-child")
    let error = await #expect(throws: VMLabError.self) {
      try await channel.run(
        ExecRequest(
          command: "while :; do touch '\(marker.path)'; sleep 1; done",
          timeout: .milliseconds(500)))
    }
    #expect(error?.code == .timeout)
    // Well past the late start: the command never ran (or was killed at once).
    try await Task.sleep(for: .seconds(4))
    try? FileManager.default.removeItem(at: marker)
    try await Task.sleep(for: .seconds(2))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func sshFailureIsGuestUnreachable() async throws {
    let f = try Fixture()
    let error = await #expect(throws: VMLabError.self) {
      try await f.channel.run(
        ExecRequest(
          command: "echo 'ssh: connect to host x port 1: Connection refused' >&2; exit 255"))
    }
    #expect(error?.code == .guestUnreachable)
    #expect(error?.data["tried"] == .array([.string("ssh")]))
  }

  @Test func remoteCommandShape() {
    let request = ExecRequest(command: "id -un", user: "root")
    let remote = RemoteShell.foreground(request, job: "j-1", loginUser: "debian")
    #expect(remote.hasPrefix("sudo -n -u 'root' -H -- /bin/sh -c '"))
    #expect(remote.hasSuffix(" vmlab 'j-1' 'exec \"${SHELL:-/bin/sh}\" -c '\\''id -un'\\'''"))
    let same = RemoteShell.foreground(
      ExecRequest(command: "x", user: "debian"), job: "j-1", loginUser: "debian")
    #expect(same.hasPrefix("/bin/sh -c '"))
  }

  @Test func quotingAndNames() {
    #expect(RemoteShell.quote("a'b") == #"'a'\''b'"#)
    #expect(RemoteShell.isValidEnvironmentName("_A1"))
    #expect(!RemoteShell.isValidEnvironmentName("1A"))
    #expect(!RemoteShell.isValidEnvironmentName("A-B"))
    #expect(!RemoteShell.isValidEnvironmentName(""))
  }
}
