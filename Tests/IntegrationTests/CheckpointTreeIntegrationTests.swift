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
      features: [.serial, .netNAT, .checkpointDisk, .checkpointLive], prepare: GuestSSH.prepare)
    do {
      let id = guest.record.id
      let manager = guest.manager
      var port = try #require(guest.record.runtime?.sshPort)
      try await GuestSSH.waitForSSH(guest, port: port)

      let a = try await manager.createCheckpoint(id, name: "A")
      #expect(a.node.mode == .live)
      #expect(try GuestSSH.run(guest, port: port, "echo b > /home/debian/marker && sync") == 0)
      let b = try await manager.createCheckpoint(id, name: "B")
      #expect(b.node.parent == a.node.id)

      _ = try await manager.restoreCheckpoint(id, name: "A")
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(try GuestSSH.run(guest, port: port, "test -e /home/debian/marker") == 1)
      _ = try await manager.restoreCheckpoint(id, name: "B")
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(try GuestSSH.run(guest, port: port, "test -e /home/debian/marker") == 0)
      #expect(try await manager.checkpoints(of: id).current == b.node.id)

      // checkpoint_stop and start: the guest comes back from its saved memory.
      #expect(try GuestSSH.run(guest, port: port, "echo s > /dev/shm/suspended") == 0)
      let suspended = try #require(try await manager.perform(.checkpointStop, on: id))
      #expect(suspended.state == .suspended)
      let resumed = try #require(try await manager.perform(.start, on: id))
      port = try #require(resumed.runtime?.sshPort)
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(try GuestSSH.run(guest, port: port, "test -e /dev/shm/suspended") == 0)
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

  /// The VZ Linux half of R-800's Verify. VZ checkpoints (save/restore and disk clones) come from
  /// R-608, which is not built: VZBackend has no CheckpointProvider yet.
  // TODO(R-608): enable once VZBackend.checkpoints(_:) exists, mirroring the QEMU test above.
  @Test(.disabled("TODO(R-608): VZ checkpoints are not built yet"))
  func vzLinuxRestoresEachSideOfTheTree() async throws {}
}
