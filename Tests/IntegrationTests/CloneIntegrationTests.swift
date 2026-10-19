import Foundation
import Testing
import VMLabCore
import VMLabQEMU

/// R-803 Verify (integration): clone a running QEMU guest from a live checkpoint, boot the clone,
/// it has the checkpoint's file (and not what the source wrote later); the original is untouched
/// by what the clone writes.
@Suite struct CloneIntegrationTests {
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func cloneFromACheckpointBootsWithItsFiles() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .netNAT, .checkpointDisk, .checkpointLive])
    var cloneGuest: QEMUGuest?
    do {
      let id = guest.record.id
      let manager = guest.manager
      let port = try #require(guest.record.runtime?.sshPort)
      try await GuestSSH.waitForSSH(guest, port: port)
      #expect(
        try await GuestSSH.run(guest, port: port, "echo cp > /home/debian/at-checkpoint && sync")
          == 0)
      _ = try await manager.createCheckpoint(id, name: "A")
      #expect(
        try await GuestSSH.run(
          guest, port: port, "rm /home/debian/at-checkpoint && echo l > /home/debian/later && sync")
          == 0)

      let clone = try await manager.clone(id, name: "copy", from: "A")
      #expect(clone.clonedFrom?.vm == id)
      let chain = try #require(clone.backingChain)
      #expect(chain.first?.hasPrefix(guest.home.appending(path: "vms/\(id)/backing/").path) == true)
      #expect(QEMUCommandLine.mac(for: clone.id) != QEMUCommandLine.mac(for: id))

      let started = try #require(try await manager.performAdmitted(.start, on: clone.id))
      let twin = QEMUGuest(
        home: guest.home, manager: manager, backend: guest.backend, backends: guest.backends,
        record: started,
        machine: try await guest.backend.machine(for: started))
      cloneGuest = twin
      let clonePort = try #require(started.runtime?.sshPort)
      try await GuestSSH.waitForSSH(twin, port: clonePort)
      #expect(
        try await GuestSSH.run(twin, port: clonePort, "test -e /home/debian/at-checkpoint") == 0)
      #expect(try await GuestSSH.run(twin, port: clonePort, "test -e /home/debian/later") == 1)
      #expect(
        try await GuestSSH.run(twin, port: clonePort, "echo c > /home/debian/clone-only && sync")
          == 0)

      #expect(try await GuestSSH.run(guest, port: port, "test -e /home/debian/clone-only") == 1)
      #expect(try await GuestSSH.run(guest, port: port, "test -e /home/debian/later") == 0)
    } catch {
      if let cloneGuest { try? await guest.backend.kill(cloneGuest.record) }
      await guest.shutdown()
      throw error
    }
    if let cloneGuest { try? await guest.backend.kill(cloneGuest.record) }
    await guest.shutdown()
  }
}
