import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_lifecycle` through `VMManager` and the fake backend.
@Suite struct VMLifecycleHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  static func act(_ action: String, on vm: String = "web", in f: Fixture) async throws(VMLabError)
    -> ToolResult
  {
    try await ToolHandlers.call(
      "vm_lifecycle", arguments: .object(["vm": .string(vm), "action": .string(action)]),
      context: f.context)
  }

  @Test func walksThePowerStates() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    #expect(try await Self.act("start", in: f).value["state"] == .string("running"))
    #expect(f.progress.messages.contains { $0.hasPrefix("starting vm-") })
    #expect(try await Self.act("pause", in: f).value["state"] == .string("paused"))
    #expect(try await Self.act("resume", in: f).value["state"] == .string("running"))
    #expect(try await Self.act("reset", in: f).value["state"] == .string("running"))
    let stopped = try await Self.act("stop", in: f)
    #expect(stopped.value["state"] == .string("stopped"))
    #expect(stopped.value["vm"]?["name"] == .string("web"))
    #expect(stopped.value["durationMs"]?.numberValue != nil)
    let destroyed = try await Self.act("destroy", in: f)
    #expect(destroyed.value["state"] == .string("destroyed"))
    #expect(f.vmDirectories().isEmpty)
  }

  /// P3: destroying a VM closes and drops its display session (and its debug session).
  @Test func destroyForgetsTheDisplaySession() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let display = FakeDisplay()
    var context = f.context
    context.displays = DisplaySessions(connectors: DisplayConnectorRegistry(display))
    _ = try await f.create(["autostart": .bool(false)])
    let id = try context.store.find("web").id
    _ = try await context.displays.session(
      vm: id, endpoint: DisplayEndpoint(address: .unixSocket(path: "/tmp/v.sock"), hostSide: true))
    await context.displays.setCursor(vm: id, x: 1, y: 2)
    _ = try await ToolHandlers.call(
      "vm_lifecycle", arguments: .object(["vm": .string("web"), "action": .string("destroy")]),
      context: context)
    #expect(await context.displays.cursor(vm: id) == nil)
    #expect(display.events.contains(.close))
  }

  /// R-400: a start whose guest gives no SSH endpoint still runs, with `ssh_unreachable`.
  @Test func startCarriesTheSSHWarning() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    let started = try await Self.act("start", in: f)
    #expect(started.value["state"] == .string("running"))
    #expect(started.warnings.contains { $0.hasPrefix("ssh_unreachable:") })
  }

  @Test func illegalTransitionIsWrongState() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let error = await #expect(throws: VMLabError.self) { try await Self.act("start", in: f) }
    #expect(error?.code == .wrongState)
    #expect(f.backend.operations == [.create, .start])
  }

  @Test func unknownVMAndCheckpointStopAreRefused() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let missing = await #expect(throws: VMLabError.self) {
      try await Self.act("stop", on: "nope", in: f)
    }
    #expect(missing?.code == .vmNotFound)
    _ = try await f.create(["autostart": .bool(false)])
    let checkpoint = await #expect(throws: VMLabError.self) {
      try await Self.act("checkpoint_stop", in: f)
    }
    #expect(checkpoint?.code == .invalidRequest)
  }

  @Test func cancelledStartWhileWaitingForASlotStartsNothing() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    // Hold every slot of a one-slot gate so the start waits in admit.
    var limits = ResourceLimits.defaults
    limits.parallelStarts = 1
    let gate = StartGate(limits: limits)
    let held = try await gate.admit(
      Inventory.Guest(id: "other", profile: .qemuHVF, os: .linux, memoryGB: 0),
      running: { .empty }, host: f.context.hostFacts())
    var context = f.context
    context.startGate = gate
    let call = Task {
      try await ToolHandlers.call(
        "vm_lifecycle", arguments: .object(["vm": .string("web"), "action": .string("start")]),
        context: context)
    }
    while await gate.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
    call.cancel()
    let outcome = await call.result
    guard case .failure(let error) = outcome else {
      Issue.record("a cancelled start returned a result")
      return
    }
    #expect((error as? VMLabError)?.data["cancelled"] == .bool(true))
    #expect(!f.backend.operations.contains(.start))
    #expect(try f.context.store.find("web").state == .created)
    await gate.release(held)
  }

  // MARK: clone (R-803)

  static func lifecycle(_ arguments: [String: JSONValue], in f: Fixture) async throws(VMLabError)
    -> ToolResult
  {
    try await ToolHandlers.call("vm_lifecycle", arguments: .object(arguments), context: f.context)
  }

  @Test func cloneMakesANewCreatedVM() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    _ = try await ToolHandlers.call(
      "vm_checkpoint",
      arguments: .object([
        "vm": .string("web"), "action": .string("create"), "name": .string("A"),
      ]), context: f.context)
    let result = try await Self.lifecycle(
      [
        "vm": .string("web"), "action": .string("clone"), "name": .string("web-2"),
        "from": .string("A"),
      ], in: f)
    #expect(result.value["vm"]?["name"] == .string("web-2"))
    #expect(result.value["source"]?["name"] == .string("web"))
    #expect(result.value["state"] == .string("created"))
    #expect(result.value["from"] == .string("A"))
    #expect(result.value["plan"]?["profile"] == .string("qemu-hvf"))
    #expect(result.value["backingChain"]?.arrayValue?.count == 1)
    let clone = try f.context.store.find("web-2")
    #expect(clone.clonedFrom?.checkpointName == "A")

    // Without a name the clone is named by its id.
    let unnamed = try await Self.lifecycle(
      ["vm": .string("web"), "action": .string("clone")], in: f)
    #expect(unnamed.value["vm"]?["name"] == unnamed.value["vm"]?["id"])
  }

  /// R-805: destroy refuses while a clone's disk reads this one, unless force.
  @Test func destroyNeedsForceWhileAClonesDiskDependsOnIt() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    _ = try await Self.lifecycle(
      ["vm": .string("web"), "action": .string("clone"), "name": .string("copy")], in: f)
    let refused = await #expect(throws: VMLabError.self) { try await Self.act("destroy", in: f) }
    #expect(refused?.code == .invalidRequest)
    let forced = try await Self.lifecycle(
      ["vm": .string("web"), "action": .string("destroy"), "force": .bool(true)], in: f)
    #expect(forced.value["state"] == .string("destroyed"))
    #expect(forced.warnings.contains { $0.hasPrefix("destroyed with force") })
  }
}

@Suite struct VMLifecycleTimeoutHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  @Test func timeoutSecondsIsHonouredOrNamedAsIgnored() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    func act(_ action: String, _ seconds: Int) async throws(VMLabError) -> ToolResult {
      try await ToolHandlers.call(
        "vm_lifecycle",
        arguments: .object([
          "vm": .string("web"), "action": .string(action),
          "timeoutSeconds": .number(Double(seconds)),
        ]), context: f.context)
    }
    #expect(try await act("start", 30).warnings.allSatisfy { !$0.contains("timeoutSeconds") })
    let paused = try await act("pause", 30)
    #expect(paused.warnings.contains("timeoutSeconds applies to start and stop; pause ignores it"))
    _ = try await act("resume", 30)
    #expect(try await act("stop", 9).value["state"] == .string("stopped"))
    let zero = await #expect(throws: VMLabError.self) { try await act("start", 0) }
    #expect(zero?.data["field"] == .string("timeoutSeconds"))
  }
}
