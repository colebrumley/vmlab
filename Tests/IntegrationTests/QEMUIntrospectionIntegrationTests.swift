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

  /// R-1205 Verify (integration): a 1 MB `vm_memory_dump` to a `local` path under `$TMPDIR` is
  /// that size and starts with the bytes `vm_debug read_memory` returns at the same address. The
  /// CPU is halted at its reset vector, MMU off, so the debugger's address is the physical one.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(4)))
  func dumpToLocalPath() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .gdb, .haltAtStart, .memoryDump, .netNAT], memoryGB: 1,
      boot: BootSpec(haltAtStart: true))
    let debug = DebugIntegrationTests.Debugger(guest)
    let folder = FileManager.default.temporaryDirectory.appending(path: "vmlab-dump-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let local = folder.appending(path: "ram.raw")
      let read = try await debug(
        "read_memory", ["address": .string("0x40000000"), "size": .number(64)])
      let expected = try #require(read["bytes"]?.stringValue)
      let dump = try await ToolHandlers.call(
        "vm_memory_dump",
        arguments: .object([
          "vm": .string(guest.record.id), "address": .string("0x40000000"),
          "size": .number(1_048_576), "local": .string(local.path),
        ]), context: debug.context)
      let path = try #require(dump.value["path"]?.stringValue)
      #expect(path == PathPolicy.canonical(local.path))
      let data = try Data(contentsOf: URL(filePath: path))
      #expect(data.count == 1_048_576)
      #expect(data.prefix(64).map { String(format: "%02x", $0) }.joined() == expected)
      #expect(!FileManager.default.fileExists(atPath: path + ".part"))
    } catch {
      await debug.close()
      await guest.shutdown()
      throw error
    }
    await debug.close()
    await guest.shutdown()
  }
}
