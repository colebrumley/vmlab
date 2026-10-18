import Foundation
import Testing
import VMLabCore
import VMLabQEMU

/// Host-side SSH into a test guest with the key `GuestSSH.prepare` dropped in its directory. The
/// exec channel (R-400) is not used here: these tests only need to change the guest's disk.
enum GuestSSH {
  /// Generates `<vm>/id_ed25519`, so `QEMUBackend` seeds the guest with its public half.
  static func prepare(_ vmDirectory: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
    process.arguments = [
      "-q", "-t", "ed25519", "-N", "", "-f", vmDirectory.appending(path: "id_ed25519").path,
    ]
    try process.run()
    process.waitUntilExit()
  }

  /// Runs `command` as `debian` over the forwarded port; returns the exit status (255: no SSH).
  static func run(_ guest: QEMUGuest, port: Int, _ command: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ssh")
    process.arguments = [
      "-i", guest.home.appending(path: "vms/\(guest.record.id)/id_ed25519").path,
      "-p", "\(port)", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR",
      "debian@127.0.0.1", command,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// Retries `true` until SSH answers.
  static func waitForSSH(_ guest: QEMUGuest, port: Int, timeout: Duration = .seconds(180))
    async throws
  {
    let deadline = ContinuousClock.now + timeout
    while try run(guest, port: port, "true") != 0 {
      guard ContinuousClock.now < deadline else {
        throw VMLabError(code: .timeout, message: "SSH did not come up", hint: "")
      }
      try await Task.sleep(for: .seconds(2))
    }
  }
}

@Suite struct QEMUCheckpointIntegrationTests {
  /// R-307 Verify (integration): a disk checkpoint of the stopped guest, a file written in the
  /// guest afterwards, restore: the file is gone.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func stoppedCheckpointRewindsTheDisk() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .netNAT, .checkpointDisk], prepare: GuestSSH.prepare)
    do {
      let id = guest.record.id
      try await GuestSSH.waitForSSH(guest, port: try #require(guest.record.runtime?.sshPort))
      let stopped = try #require(try await guest.manager.perform(.stop, on: id))
      let checkpoints = try await guest.backend.checkpoints(stopped)
      try await checkpoints.create(id: "before", mode: .disk)

      var running = try #require(try await guest.manager.performAdmitted(.start, on: id))
      var port = try #require(running.runtime?.sshPort)
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(try GuestSSH.run(guest, port: port, "echo hi > /home/debian/marker && sync") == 0)
      #expect(try GuestSSH.run(guest, port: port, "test -e /home/debian/marker") == 0)

      // A running guest has no disk checkpoints on QEMU: wrong_state, nothing stopped for us.
      await #expect {
        try await guest.backend.checkpoints(running).restore(id: "before", mode: .disk)
      } throws: { ($0 as? VMLabError)?.code == .wrongState }

      let again = try #require(try await guest.manager.perform(.stop, on: id))
      try await guest.backend.checkpoints(again).restore(id: "before", mode: .disk)
      running = try #require(try await guest.manager.performAdmitted(.start, on: id))
      port = try #require(running.runtime?.sshPort)
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(try GuestSSH.run(guest, port: port, "test -e /home/debian/marker") == 1)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-307 Verify (integration): the probe runs and writes `host-facts.json`; when it says `yes`,
  /// a live checkpoint and restore keep a shell session's history. The session is a login on the
  /// serial console rather than SSH: the exec channel (R-400) is not on main yet, and a restored
  /// guest's TCP state would not match the host's side of an SSH connection anyway.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func probeRecordsTheAnswerAndLiveRestoreKeepsShellHistory() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-probe")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let registry = SlowProbeRegistry()
    registry.register(QEMULiveSnapshotProbe())
    let facts = HostProbe(home: home).gather()
    let outcomes = await registry.runAll(SlowProbeContext(home: home, facts: facts))
    let outcome = try #require(outcomes.first { $0.probe == .qemuHVFLiveSnapshot })
    #expect(outcome.status == .ran, "\(outcome.note ?? "")")
    let stored = try SlowProbes.load(from: SlowProbes.url(home: home))
    #expect(stored.result(.qemuHVFLiveSnapshot) == outcome.result)
    print("qemu_hvf_live_snapshot = \(outcome.result.rawValue)")
    guard outcome.result == .yes else { return }

    let guest = try await QEMUGuest.boot(
      features: [.serial, .netNAT, .checkpointDisk, .checkpointLive], prepare: GuestSSH.prepare)
    do {
      let port = try #require(guest.record.runtime?.sshPort)
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(
        try GuestSSH.run(guest, port: port, "echo 'debian:vmlab-test' | sudo chpasswd") == 0)

      let serial = guest.machine.serial
      var mark = try await serial.write("\r")
      _ = try await serial.wait(for: "login: ", since: mark, timeout: .seconds(30))
      mark = try await serial.write("debian\r")
      _ = try await serial.wait(for: "Password: ", since: mark, timeout: .seconds(30))
      mark = try await serial.write("vmlab-test\r")
      _ = try await serial.wait(for: "\\$ ", since: mark, timeout: .seconds(30))
      mark = try await serial.write("echo vmlab-one\r")
      _ = try await serial.wait(for: "\\$ ", since: mark, timeout: .seconds(30))

      let checkpoints = try await guest.backend.checkpoints(guest.record)
      try await checkpoints.create(id: "live-1", mode: .live)
      mark = try await serial.write("echo vmlab-two\r")
      _ = try await serial.wait(for: "\\$ ", since: mark, timeout: .seconds(30))
      try await checkpoints.restore(id: "live-1", mode: .live)
      #expect(try await guest.machine.status().running)

      mark = try await serial.write("history\r")
      _ = try await serial.wait(for: "history\\s+[\\s\\S]*\\$ ", since: mark, timeout: .seconds(30))
      let output = await serial.read(since: mark).text
      #expect(output.contains("echo vmlab-one"), "\(output)")
      #expect(!output.contains("echo vmlab-two"), "\(output)")

      try await checkpoints.delete(id: "live-1")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
