import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite struct QEMUIntegrationTests {
  /// R-302 Verify (integration): boot `debian-13-arm64` under `qemu-hvf`, `query-status` says
  /// `running`, and `system_powerdown` (vm_lifecycle stop) finishes within 60 s.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
  func debianBootsUnderHVFAndPowersDown() async throws {
    let guest = try await QEMUGuest.boot()
    do {
      #expect(guest.record.state == .running)
      #expect(guest.record.runtime?.qmpSocket == guest.machine.layout.qmpSocket.path)
      let status = try await guest.machine.status()
      #expect(status == QMPStatus(status: "running", running: true))

      // Let the guest get far enough to honour the ACPI power button.
      _ = try await guest.machine.serial.wait(for: "login:", since: 0, timeout: .seconds(90))
      let started = ContinuousClock.now
      let stopped = try await guest.manager.perform(.stop, on: guest.record.id)
      let elapsed = ContinuousClock.now - started
      #expect(elapsed < .seconds(60), "powerdown took \(elapsed)")
      #expect(stopped?.state == .stopped)
      #expect(!guest.machine.isRunning)

      // Reconnect by path: start again, drop the client, attach a fresh backend to the same home.
      let restarted = try await guest.manager.performAdmitted(.start, on: guest.record.id)
      // QEMU serves one QMP client at a time: the old server's connection goes first.
      if let restarted { await (try guest.backend.machine(for: restarted)).disconnect() }
      let fresh = QEMUBackend(profile: .qemuHVF, store: Store(home: guest.home))
      let record = try Store(home: guest.home).load(id: guest.record.id)
      let attached = try await fresh.machine(for: record)
      #expect(try await attached.status().running)
      try await fresh.kill(record)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
