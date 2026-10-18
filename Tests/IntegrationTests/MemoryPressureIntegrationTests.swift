import Foundation
import Testing
import VMLabCore
import VMLabMCP

/// `mem-pressure-gate`: a real `vm_create` on this host passes the live host-memory admission and
/// its QEMU process is then counted host-wide; the same call through a gate whose reader reports
/// a host short of memory is refused with `limit_memory` and leaves nothing behind.
@Suite(.serialized) struct MemoryPressureIntegrationTests {
  static func create(_ context: ToolContext, name: String) async throws -> JSONValue {
    try await ToolHandlers.call(
      "vm_create",
      arguments: .object([
        "name": .string(name), "requirements": FleetIntegrationTests.requirements,
      ]), context: context
    ).value
  }

  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(5)))
  func liveStartPassesAndAShortHostRefuses() async throws {
    let lab = try LabHome(tag: "m")
    do {
      let live = FleetIntegrationTests.context(lab)
      let created = try await Self.create(live, name: "fits")
      #expect(created["state"] == .string("running"), "\(created)")
      let record = try #require(try lab.store.list().records.first)
      let pid = try #require(record.runtime?.pid)
      let seen = LiveHostMemory(recognizers: IntegrationAdmission.recognizers).snapshot()
      let process = try #require(seen.guests.first { $0.pid == pid }, "\(seen.guests)")
      #expect(process.memoryGB == 2)
      #expect(process.directory == lab.store.directory(of: record.id).path)

      var short = live
      short.startGate = StartGate(
        hostMemory: HostMemoryGuard(
          reader: FixedHostMemory(
            HostMemorySnapshot(pressure: .normal, availableGB: 3, guests: seen.guests))))
      let error = await #expect(throws: VMLabError.self) {
        _ = try await Self.create(short, name: "short")
      }
      #expect(error?.code == .limitMemory)
      #expect(error?.data["availableGB"] == .number(3))
      #expect(error?.data["hostGuests"] == .number(Double(seen.guests.count)))
      #expect(try lab.store.list().records.map(\.name) == ["fits"])
    } catch {
      await lab.shutdown()
      throw error
    }
    await lab.shutdown()
  }
}
