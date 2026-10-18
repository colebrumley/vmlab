import Foundation
import Testing
import VMLabCore

@testable import VMLabVZ

@Suite struct PasswordSSHTests {
  /// The password reaches ssh only through the askpass script's environment, never an argument.
  @Test func passwordIsNeverAnArgument() async throws {
    let dir = TartTests.temporary()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var ssh = PasswordSSH(user: "admin", host: "192.168.64.9", password: "s3cret", scratch: dir)
    #expect(!ssh.arguments("true").contains { $0.contains("s3cret") })
    #expect(ssh.arguments("sw_vers").suffix(2) == ["admin@192.168.64.9", "sw_vers"])

    // Stand-in ssh: run the askpass script the way ssh would and echo stdin.
    let fake = dir.appending(path: "fake-ssh")
    try TestScripts.install("#!/bin/sh\n\"$SSH_ASKPASS\" prompt\ncat\n", at: fake)
    // A script that has run before starts at once (see `TestScripts`); run() keeps it.
    try TestScripts.install(PasswordSSH.askpassScript, at: ssh.askpass)
    ssh.ssh = fake.path
    let output = await ssh.run("ignored", input: Data("key\n".utf8), timeout: .seconds(10))
    #expect(output?.status == 0)
    #expect(output?.output == "s3cret\nkey\n")
  }

  /// The askpass script is written once per VM directory, not on every run: each new file costs
  /// a macOS executable assessment (0.25 s, seconds on a busy host) on its first exec.
  @Test func theAskpassScriptIsNotRewrittenOnEveryRun() async throws {
    let dir = TartTests.temporary()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var ssh = PasswordSSH(user: "admin", host: "192.168.64.9", password: "pw", scratch: dir)
    ssh.ssh = "/usr/bin/true"
    #expect(await ssh.run("x", timeout: .seconds(30))?.status == 0)
    let first = try FileManager.default.attributesOfItem(atPath: ssh.askpass.path)
    #expect(await ssh.run("x", timeout: .seconds(30))?.status == 0)
    let second = try FileManager.default.attributesOfItem(atPath: ssh.askpass.path)
    #expect(first[.systemFileNumber] as? Int == second[.systemFileNumber] as? Int)
    #expect((second[.posixPermissions] as? Int) == 0o700)
    // A tampered script is replaced.
    try Data("#!/bin/sh\necho other\n".utf8).write(to: ssh.askpass)
    #expect(await ssh.run("x", timeout: .seconds(30))?.status == 0)
    #expect(try Data(contentsOf: ssh.askpass) == Data(PasswordSSH.askpassScript.utf8))
  }

  @Test func timeoutKillsTheCommand() async {
    let clock = ContinuousClock()
    let begun = clock.now
    let output = await HostCommand.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
    #expect(output == nil)
    #expect(clock.now - begun < .seconds(10))
  }
}
