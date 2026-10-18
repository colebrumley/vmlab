import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_debug` through `VMManager`, the fake backend and a scripted debug target.
@Suite struct VMDebugHandlerTests {
  struct Fixture {
    let base: VMCreateHandlerTests.Fixture
    let connector = FakeDebugConnector()
    let context: ToolContext

    init() throws {
      base = try VMCreateHandlerTests.Fixture()
      var context = base.context
      context.debug = DebugSessions(connector: connector)
      self.context = context
    }

    func debug(_ action: String, _ extra: [String: JSONValue] = [:]) async throws(VMLabError)
      -> JSONValue
    {
      var arguments: [String: JSONValue] = ["vm": .string("web"), "action": .string(action)]
      arguments.merge(extra) { $1 }
      return try await ToolHandlers.call(
        "vm_debug", arguments: .object(arguments), context: context
      ).value
    }
  }

  @Test func isListedAndNeedsARunningVMWithGDB() async throws {
    #expect(ToolHandlers.specs.contains { $0.name == "vm_debug" })
    let f = try Fixture()
    defer { f.base.cleanUp() }
    _ = try await f.base.create(["autostart": .bool(false)])
    let stopped = await #expect(throws: VMLabError.self) { try await f.debug("info") }
    #expect(stopped?.code == .wrongState)
    let bad = await #expect(throws: VMLabError.self) { try await f.debug("explode") }
    #expect(bad?.code == .invalidRequest)
  }

  @Test func infoNamesTheEndpointWithoutAttaching() async throws {
    let f = try Fixture()
    defer { f.base.cleanUp() }
    _ = try await f.base.create()
    let info = try await f.debug("info", ["symbolFile": .string("/tmp/vmlinux")])
    #expect(info["endpoint"] == .string("127.0.0.1:1234"))
    #expect(info["attached"] == .bool(false))
    #expect(info["stopped"] == .null)
    #expect(info["symbolFile"] == .string("/tmp/vmlinux"))
    #expect(
      info["connect"]?["gdb"]
        == .string("gdb '/tmp/vmlinux' -ex 'target remote 127.0.0.1:1234'"))
    #expect(f.connector.targets.isEmpty)
    #expect(info["warnings"] == .array([]))
  }

  @Test func haltRegistersStepBreakAndWait() async throws {
    let f = try Fixture()
    defer { f.base.cleanUp() }
    _ = try await f.base.create()
    let halted = try await f.debug("halt")
    #expect(halted["stopped"] == .bool(true))
    #expect(halted["reason"] == .string("halted"))
    #expect(halted["pc"] == .string("0x40080000"))
    #expect(halted["attached"] == .bool(true))

    let registers = try await f.debug("registers")
    #expect(registers["registers"]?["sp"] == .string("0xffff00008000fff0"))
    #expect(registers["registers"]?["v0"] == .null)
    #expect(registers["pc"] == .string("0x40080000"))

    let stepped = try await f.debug("step")
    #expect(stepped["reason"] == .string("step"))
    #expect(stepped["pc"] == .string("0x40080004"))

    let added = try await f.debug("breakpoint_add", ["address": .string("0x40080100")])
    #expect(
      added["breakpoints"]
        == .array([.object(["address": .string("0x40080100"), "kind": .string("software")])])
    )
    let watch = try await f.debug(
      "breakpoint_add",
      ["address": .string("0x2000"), "kind": .string("watch_access"), "size": .number(4)])
    #expect(watch["breakpoints"]?.arrayValue?.last?["size"] == .number(4))

    let resumed = try await f.debug("continue")
    #expect(resumed["stopped"] == .bool(false))
    f.connector.latest?.stopNext(DebugStop(reason: .signal, signal: 5, pc: 0x4008_0100))
    let hit = try await f.debug("wait", ["timeoutSeconds": .number(1)])
    #expect(hit["reason"] == .string("breakpoint"))
    #expect(hit["pc"] == .string("0x40080100"))

    let removed = try await f.debug("breakpoint_remove", ["address": .string("0x40080100")])
    #expect(removed["breakpoints"]?.arrayValue?.count == 1)
    #expect(try await f.debug("breakpoints")["breakpoints"]?.arrayValue?.count == 1)
  }

  @Test func readsAndWritesMemory() async throws {
    let f = try Fixture()
    defer { f.base.cleanUp() }
    _ = try await f.base.create()
    _ = try await f.debug(
      "write_memory", ["address": .string("0x1000"), "data": .string("48690a00")])
    let read = try await f.debug("read_memory", ["address": .string("4096"), "size": .number(4)])
    #expect(read["bytes"] == .string("48690a00"))
    #expect(read["ascii"] == .string("Hi.."))
    #expect(read["address"] == .string("0x1000"))
    let big = try await f.debug(
      "read_memory", ["address": .string("0x1000"), "size": .number(300)])
    #expect(big["ascii"] == nil)
    #expect(big["bytes"]?.stringValue?.count == 600)

    for (extra, field) in [
      (["size": JSONValue.number(4)], "address"),
      (["address": .string("main")], "address"),
      (["address": .string("0x1000")], "size"),
      (["address": .string("0x1000"), "size": .number(1_048_576)], "size"),
    ] {
      let error = await #expect(throws: VMLabError.self) { try await f.debug("read_memory", extra) }
      #expect(error?.code == .invalidRequest)
      #expect(error?.data["field"] == .string(field))
    }
    let odd = await #expect(throws: VMLabError.self) {
      try await f.debug("write_memory", ["address": .string("0x1000"), "data": .string("abc")])
    }
    #expect(odd?.data["field"] == .string("data"))
    let size = await #expect(throws: VMLabError.self) {
      try await f.debug(
        "breakpoint_add",
        ["address": .string("0x1000"), "kind": .string("watch_write"), "size": .number(3)])
    }
    #expect(size?.data["field"] == .string("size"))
  }

  /// R-703: vm_lifecycle reset puts the session's points in again; destroy drops the session.
  @Test func resetReinsertsAndDestroyDrops() async throws {
    let f = try Fixture()
    defer { f.base.cleanUp() }
    _ = try await f.base.create()
    _ = try await f.debug("breakpoint_add", ["address": .string("0x1000")])
    let lifecycle = { (action: String) async throws(VMLabError) -> ToolResult in
      try await ToolHandlers.call(
        "vm_lifecycle", arguments: .object(["vm": .string("web"), "action": .string(action)]),
        context: f.context)
    }
    let reset = try await lifecycle("reset")
    #expect(reset.warnings.isEmpty)
    #expect(f.connector.latest?.log.suffix(2) == ["remove software 1000", "insert software 1000"])
    let id = try f.context.store.find("web").id
    #expect(f.context.debug.existing(id) != nil)
    _ = try await lifecycle("destroy")
    #expect(f.context.debug.existing(id) == nil)
  }

  /// R-704: the three watchpoint kinds with their sizes, and a watchpoint stop with its address.
  @Test func watchpointsOfEveryKind() async throws {
    let f = try Fixture()
    defer { f.base.cleanUp() }
    _ = try await f.base.create()
    for (kind, size) in [("watch_write", 8), ("watch_read", 4), ("watch_access", 1)] {
      _ = try await f.debug(
        "breakpoint_add",
        ["address": .string("0x1000"), "kind": .string(kind), "size": .number(Double(size))])
    }
    #expect(
      f.connector.latest?.inserted == [
        DebugPoint(address: 0x1000, kind: .watchWrite, size: 8),
        DebugPoint(address: 0x1000, kind: .watchRead, size: 4),
        DebugPoint(address: 0x1000, kind: .watchAccess, size: 1),
      ])
    _ = try await f.debug("continue")
    f.connector.latest?.stopNext(
      DebugStop(reason: .watchpoint, signal: 5, pc: 0x4008_0010, watchAddress: 0x1000))
    let stop = try await f.debug("wait", ["timeoutSeconds": .number(1)])
    #expect(stop["reason"] == .string("watchpoint"))
    #expect(stop["watchAddress"] == .string("0x1000"))
    _ = try await f.debug(
      "breakpoint_remove", ["address": .string("0x1000"), "kind": .string("watch_read")])
    #expect(f.connector.latest?.inserted.count == 2)
  }

  @Test func busyStubIsDebugBusy() async throws {
    let f = try Fixture()
    defer { f.base.cleanUp() }
    _ = try await f.base.create()
    f.connector.setBusy(true)
    let error = await #expect(throws: VMLabError.self) { try await f.debug("halt") }
    #expect(error?.code == .debugBusy)
    let info = try await f.debug("info")
    #expect(info["attached"] == .bool(false))
    #expect(info["endpoint"] == .string("127.0.0.1:1234"))
    #expect(info["note"]?.stringValue?.hasPrefix("another debugger") == true)
    f.connector.setBusy(false)
    _ = try await f.debug("halt")
    #expect(try await f.debug("info")["note"]?.stringValue?.hasPrefix("vmlab holds") == true)
  }

  @Test func planWithoutGDBIsCapabilityMissing() async throws {
    let f = try Fixture()
    defer { f.base.cleanUp() }
    _ = try await f.base.create()
    let id = try f.context.store.find("web").id
    _ = try f.context.store.update(id: id) { (record: inout VMRecord) throws(VMLabError) in
      record.features.removeAll { $0 == .gdb }
    }
    let error = await #expect(throws: VMLabError.self) { try await f.debug("info") }
    #expect(error?.code == .capabilityMissing)
    #expect(error?.data["feature"] == .string("gdb"))
  }

  @Test func parsesAddresses() {
    #expect(VMDebugHandler.parseAddress("0xFFFF_8000_1000_0000") == 0xffff_8000_1000_0000)
    #expect(VMDebugHandler.parseAddress("4096") == 4096)
    #expect(VMDebugHandler.parseAddress("ffff") == nil)
    #expect(VMDebugHandler.parseAddress("0x") == nil)
  }
}
