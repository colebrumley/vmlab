import Foundation
import Testing
import VMLabCore
import VMLabQEMU

/// R-800 Verify (integration): create A, change, create B, restore A (state matches A), restore B
/// (matches B), through `VMManager`'s tree on a real guest. Live checkpoints, so the guest keeps
/// running and SSH reads its state after each restore.
@Suite struct CheckpointTreeIntegrationTests {
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func qemuRestoresEachSideOfTheTree() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .netNAT, .checkpointDisk, .checkpointLive])
    do {
      let id = guest.record.id
      let manager = guest.manager
      var port = try #require(guest.record.runtime?.sshPort)
      try await GuestSSH.waitForSSH(guest, port: port)

      let a = try await manager.createCheckpoint(id, name: "A")
      #expect(a.node.mode == .live)
      #expect(
        try await GuestSSH.run(guest, port: port, "echo b > /home/debian/marker && sync") == 0)
      let b = try await manager.createCheckpoint(id, name: "B")
      #expect(b.node.parent == a.node.id)

      _ = try await manager.restoreCheckpoint(id, name: "A")
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(try await GuestSSH.run(guest, port: port, "test -e /home/debian/marker") == 1)
      _ = try await manager.restoreCheckpoint(id, name: "B")
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(try await GuestSSH.run(guest, port: port, "test -e /home/debian/marker") == 0)
      #expect(try await manager.checkpoints(of: id).current == b.node.id)

      // checkpoint_stop and start: the guest comes back from its saved memory.
      #expect(try await GuestSSH.run(guest, port: port, "echo s > /dev/shm/suspended") == 0)
      let suspended = try #require(try await manager.perform(.checkpointStop, on: id))
      #expect(suspended.state == .suspended)
      let resumed = try #require(try await manager.performAdmitted(.start, on: id))
      port = try #require(resumed.runtime?.sshPort)
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(try await GuestSSH.run(guest, port: port, "test -e /dev/shm/suspended") == 0)
      #expect(try await manager.checkpoints(of: id).resume == nil)

      // The suspend save is B's child, so A's subtree is all three.
      let deleted = try await manager.deleteCheckpoint(id, name: "A", recursive: true)
      #expect(deleted.count == 3)
      #expect(try await manager.checkpoints(of: id).nodes.isEmpty)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// The VZ Linux half of R-800's Verify, on R-608's save/restore and disk clones.
  @Test(.enabled(if: VZRunnerIntegrationTests.ready), .timeLimit(.minutes(10)))
  func vzLinuxRestoresEachSideOfTheTree() async throws {
    let guest = try await VZGuest.boot(
      features: [.execSSH, .serial, .checkpointDisk, .checkpointLive], tag: "t")
    defer { guest.cleanUp() }
    let id = guest.id
    let manager = guest.manager

    let a = try await manager.createCheckpoint(id, name: "A")
    #expect(a.node.mode == .live)
    #expect(await guest.ssh("echo b > /home/debian/marker && sync")?.status == 0)
    let b = try await manager.createCheckpoint(id, name: "B")
    #expect(b.node.parent == a.node.id)

    _ = try await manager.restoreCheckpoint(id, name: "A")
    let cps = guest.directory.appending(path: "checkpoints")
    #expect(await guest.ssh("test ! -e /home/debian/marker")?.status == 0)
    _ = try await manager.restoreCheckpoint(id, name: "B")
    #expect(await guest.ssh("test -e /home/debian/marker")?.status == 0)
    #expect(try await manager.checkpoints(of: id).current == b.node.id)

    // checkpoint_stop and start: the guest comes back from its saved memory.
    #expect(await guest.ssh("echo s > /dev/shm/suspended")?.status == 0)
    let suspended = try #require(try await manager.perform(.checkpointStop, on: id))
    #expect(suspended.state == .suspended)
    let resumed = try #require(try await manager.performAdmitted(.start, on: id))
    #expect(resumed.state == .running)
    #expect(await guest.ssh("test -e /dev/shm/suspended")?.status == 0)
    #expect(try await manager.checkpoints(of: id).resume == nil)

    // A disk checkpoint of the stopped guest, restored after a change.
    try await manager.perform(.stop, on: id)
    let d = try await manager.createCheckpoint(id, name: "D", mode: .disk)
    #expect(d.node.mode == .disk)
    _ = try await manager.restoreCheckpoint(id, name: "D")

    let deleted = try await manager.deleteCheckpoint(id, name: "A", recursive: true)
    #expect(deleted.count == 4)
    #expect(try await manager.checkpoints(of: id).nodes.isEmpty)
    #expect(
      (try? FileManager.default.contentsOfDirectory(
        atPath: guest.directory.appending(path: "checkpoints").path))?.isEmpty ?? true)
  }
}
