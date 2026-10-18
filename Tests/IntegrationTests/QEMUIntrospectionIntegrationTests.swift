import Foundation
import Testing
import VMLabCore
import VMLabMCP
import VMLabQEMU

@Suite struct QEMUIntrospectionIntegrationTests {
  /// R-311 Verify (integration): `pci` lists the virtio devices, and `pmemsave` of 1 MB produces
  /// a file of that size; both through the MCP handlers against a real HVF guest.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(5)))
  func pciListsVirtioAndPmemsaveWritesOneMegabyte() async throws {
    let guest = try await QEMUGuest.boot(features: [
      .serial, .netNAT, .introspection, .memoryDump,
    ])
    do {
      let context = ToolContext(
        home: guest.home, backends: guest.manager.backends, startGate: IntegrationAdmission.gate)
      let pci = try await ToolHandlers.call(
        "vm_introspect",
        arguments: .object(["vm": .string(guest.record.id), "query": .string("pci")]),
        context: context)
      let devices = (pci.value["json"]?.arrayValue ?? []).flatMap {
        $0["devices"]?.arrayValue ?? []
      }
      // Red Hat's virtio vendor id, 0x1af4: virtio-blk, virtio-net, virtio-input.
      let virtio = devices.filter { $0["id"]?["vendor"] == .number(0x1af4) }
      #expect(virtio.count >= 3, "\(devices)")

      let mtree = try await ToolHandlers.call(
        "vm_introspect",
        arguments: .object(["vm": .string(guest.record.id), "query": .string("memory_tree")]),
        context: context)
      #expect(mtree.value["text"]?.stringValue?.contains("address-space: memory") == true)

      let dump = try await ToolHandlers.call(
        "vm_memory_dump",
        arguments: .object([
          "vm": .string(guest.record.id), "address": .string("0x40000000"),
          "size": .number(1_048_576),
        ]), context: context)
      let path = try #require(dump.value["path"]?.stringValue)
      #expect(dump.value["bytes"] == .number(1_048_576))
      let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
      #expect(size == 1_048_576)
      #expect(path.contains("/vms/\(guest.record.id)/dumps/"))
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
