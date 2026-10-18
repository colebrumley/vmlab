import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_plan`, `vm_list` and `vm_inspect` over JSON-RPC on pipes (R-204), with a fixture VM made
/// through `VMManager` and the fake backend in the server's `VMLAB_HOME`.
@Suite struct MCPServerVMToolsTests {
  typealias Session = MCPServerTests.Session

  static let linux: JSONValue = .object(["os": .string("linux"), "arch": .string("arm64")])

  /// Plans over the wire, then creates and starts the plan's VM with the fake backend.
  static func fixtureVM(in session: Session, id: Int) async throws -> VMRecord {
    let response = try await session.request(
      id, "tools/call",
      MCPServerTests.call(
        "vm_plan",
        .object([
          "requirements": .object([
            "guest": linux, "require": .array([.string("serial"), .string("gdb")]),
          ]),
          "allowUnverified": .bool(true),
        ])))
    let planned = try MCPServerTests.resultObject(response)
    #expect(planned["satisfiable"] == .bool(true))
    let plan = try JSONDecoder().decode(Plan.self, from: planned.data)
    let store = session.context.store
    let registry = BackendRegistry()
    registry.register(FakeBackend(profile: plan.profile, store: store))
    let manager = VMManager(store: store, backends: registry)
    let draft = VMRecord(
      id: "", name: "web", profile: plan.profile, guest: plan.guest, features: [],
      image: "debian-13-arm64")
    let record = try await manager.create(draft, plan: plan)
    return try #require(try await manager.perform(.start, on: record.id))
  }

  @Test func impossiblePlanReturnsSuggestionsNotAnError() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let response = try await session.request(
      2, "tools/call",
      MCPServerTests.call(
        "vm_plan",
        .object([
          "requirements": .object([
            "guest": Self.linux, "require": .array([.string("rosetta"), .string("gdb")]),
          ])
        ])))
    #expect(response["error"] == nil)
    #expect(response["result"]?["isError"] == .bool(false))
    let result = try MCPServerTests.resultObject(response)
    #expect(result["satisfiable"] == .bool(false))
    #expect(result["code"] == .string("unsatisfiable"))
    #expect(result["eliminated"]?["rosetta"]?.arrayValue?.isEmpty == false)
    let suggestions = try #require(result["suggestions"]?.arrayValue)
    #expect(!suggestions.isEmpty)
    #expect(suggestions.allSatisfy { $0["drop"]?.arrayValue?.isEmpty == false })
    #expect(result["hint"]?.stringValue?.isEmpty == false)
    await session.close()
  }

  @Test func listShowsTheFixtureVM() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let vm = try await Self.fixtureVM(in: session, id: 2)
    let response = try await session.request(3, "tools/call", MCPServerTests.call("vm_list"))
    let rows = try #require(try MCPServerTests.resultObject(response)["vms"]?.arrayValue)
    #expect(rows.count == 1)
    #expect(rows.first?["id"] == .string(vm.id))
    #expect(rows.first?["name"] == .string("web"))
    #expect(rows.first?["state"] == .string("running"))
    #expect(rows.first?["profile"] == .string(vm.profile.rawValue))
    #expect(rows.first?["guest"]?["os"] == .string("linux"))
    let stopped = try await session.request(
      4, "tools/call", MCPServerTests.call("vm_list", .object(["state": .string("stopped")])))
    #expect(try MCPServerTests.resultObject(stopped)["vms"] == .array([]))
    await session.close()
  }

  @Test func inspectReturnsRecordPlanFeaturesEndpointsAndEvents() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let vm = try await Self.fixtureVM(in: session, id: 2)
    let response = try await session.request(
      3, "tools/call", MCPServerTests.call("vm_inspect", .object(["vm": .string("web")])))
    #expect(response["result"]?["isError"] == .bool(false))
    let result = try MCPServerTests.resultObject(response)
    #expect(result["vm"]?["id"] == .string(vm.id))
    #expect(result["record"]?["state"] == .string("running"))
    let plan = try JSONDecoder().decode(Plan.self, from: try #require(result["plan"]).data)
    #expect(plan.grants(.serial) && plan.grants(.gdb))
    #expect(result["features"] == .array(vm.features.map { .string($0.rawValue) }))
    #expect(result["features"]?.arrayValue?.contains(.string("gdb")) == true)
    #expect(result["endpoints"]?["gdb"] == .string("tcp:127.0.0.1:1234"))
    #expect(result["endpoints"]?["serial"]?.stringValue?.hasSuffix("serial.sock") == true)
    // R-503: QEMU's display is its host-side VNC socket.
    let display = try #require(result["endpoints"]?["display"])
    #expect(display["kind"] == .string("vnc"))
    #expect(display["hostSide"] == .bool(true))
    #expect(display["auth"] == .string("none"))
    #expect(display["address"]?.stringValue?.hasSuffix("/vnc.sock") == true)
    let events = try #require(result["events"]?.arrayValue)
    #expect(events.count == 2)
    #expect(events.first?["message"]?.stringValue?.hasPrefix("created") == true)
    #expect(result["warnings"] == .array([]))
    await session.close()
  }

  @Test func inspectKeepsOnlyTheLastTwentyEvents() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let vm = try await Self.fixtureVM(in: session, id: 2)
    let log = EventLog(vmDirectory: session.context.store.directory(of: vm.id))
    for n in 0..<25 { try await log.append(VMEvent(kind: .lifecycle, message: "event \(n)")) }
    let response = try await session.request(
      3, "tools/call", MCPServerTests.call("vm_inspect", .object(["vm": .string(vm.id)])))
    let events = try #require(try MCPServerTests.resultObject(response)["events"]?.arrayValue)
    #expect(events.count == VMInspectHandler.eventCount)
    #expect(events.last?["message"] == .string("event 24"))
    #expect(events.first?["message"] == .string("event 5"))
    await session.close()
  }

  @Test func inspectOfARecordWithoutAPlanSendsNull() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let record = try session.context.store.create(
      VMRecord(
        id: "", name: "old", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [.serial]))
    let response = try await session.request(
      2, "tools/call", MCPServerTests.call("vm_inspect", .object(["vm": .string(record.id)])))
    let result = try MCPServerTests.resultObject(response)
    #expect(result["plan"] == .null)
    #expect(result["endpoints"] == .object([:]))
    #expect(result["features"] == .array([.string("serial")]))
    await session.close()
  }
}
