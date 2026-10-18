import Foundation
import Synchronization
import Testing
import VMLabCore

@testable import VMLabMCP

/// `fleet` and `net_segment` against the fake backend, a fake switch (a script that makes the
/// sockets and sleeps) and a recorder in place of the `/etc/hosts` publisher.
@Suite struct FleetHandlerTests {
  final class Names: SegmentNaming {
    let published = Mutex<[(String, [String])]>([])
    func publish(_ segment: Segment, to targets: [SSHTarget]) async -> [String: VMLabError] {
      published.withLock { $0.append((segment.name, targets.map(\.vm))) }
      return [:]
    }
  }

  struct Fixture {
    let context: ToolContext
    let backend: FakeBackend
    let names = Names()

    init() throws {
      let base = try VMCreateHandlerTests.Fixture()
      // Short: segment port sockets must fit sun_path.
      let home = URL(filePath: "/tmp/vfl-\(UInt32.random(in: 0...UInt32.max))")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      let fakeSwitch = home.appending(path: "fake-switch")
      try """
      #!/bin/sh
      d="$VMLAB_HOME/segments/$1"
      mkdir -p "$d"
      : > "$d/switch.sock"; : > "$d/attach.sock"
      echo $$ > "$d/switch.pid"
      exec sleep 600
      """.write(to: fakeSwitch, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeSwitch.path)
      let store = Store(home: home)
      let registry = BackendRegistry()
      let backend = FakeBackend(profile: .qemuHVF, store: store)
      backend.reportSSHPort(2222)
      registry.register(backend)
      let images = ImageStore(
        home: home, catalogue: base.context.images.catalogue,
        downloader: ImagesTests.downloader(), runner: ConvertRunner(),
        searchPaths: [try ImagesTests.sandbox().bin.path])
      var context = ToolContext(
        home: home, probe: base.context.probe, backends: registry, images: images,
        startGate: StartGate())
      context.manager = VMManager(
        store: store, backends: registry, readiness: FakeReadiness(),
        segments: SegmentStore(home: home, switchBinary: fakeSwitch.path), naming: names)
      self.context = context
      self.backend = backend
      try? FileManager.default.removeItem(at: base.context.home)
    }

    func call(_ arguments: [String: JSONValue]) async throws(VMLabError) -> JSONValue {
      try await ToolHandlers.call("fleet", arguments: .object(arguments), context: context).value
    }

    func cleanUp() {
      for segment in context.manager.segments.list() {
        context.manager.segments.stopSwitch(segment.name)
      }
      try? FileManager.default.removeItem(at: context.home)
    }
  }

  @Test func createStatusListDestroy() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let created = try await f.call([
      "action": .string("create"), "name": .string("node"), "count": .number(3),
      "requirements": VMCreateHandlerTests.Fixture.requirements, "allowUnverified": .bool(true),
    ])
    let members = try #require(created["members"]?.arrayValue)
    #expect(members.map { $0["vm"]?.stringValue } == ["node-1", "node-2", "node-3"])
    #expect(members.allSatisfy { $0["state"] == .string("running") }, "\(members)")
    #expect(
      Set(members.compactMap { $0["ip"]?.stringValue })
        == ["10.1.0.10", "10.1.0.11", "10.1.0.12"])
    #expect(created["segment"] == .string("node"))
    #expect(created["plan"]?["profile"] == .string("qemu-hvf"))
    #expect(f.backend.operations.filter { $0 == .start }.count == 3)
    #expect(
      FileManager.default.fileExists(
        atPath: f.context.home.appending(path: "fleets/node.json").path))
    // Each start published the segment's names.
    #expect(f.names.published.withLock { $0.count } == 3)

    let records = try f.context.store.list().records
    #expect(records.allSatisfy { $0.fleet == "node" && $0.segment?.segment == "node" })
    let listed = try await ToolHandlers.call(
      "vm_list", arguments: .object(["fleet": .string("node")]), context: f.context
    ).value
    #expect(listed["vms"]?.arrayValue?.count == 3)

    let status = try await f.call(["action": .string("status"), "name": .string("node")])
    #expect(status["members"]?.arrayValue?.allSatisfy { $0["state"] == .string("running") } == true)
    let list = try await f.call(["action": .string("list")])
    #expect(list["fleets"]?.arrayValue?.first?["name"] == .string("node"))

    // Taken names and an existing fleet are refused up front.
    await #expect {
      try await f.call([
        "action": .string("create"), "name": .string("node"), "count": .number(1),
        "requirements": VMCreateHandlerTests.Fixture.requirements,
        "allowUnverified": .bool(true),
      ])
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }

    let destroyed = try await f.call(["action": .string("destroy"), "name": .string("node")])
    #expect(destroyed["destroyed"] == .array(["node-1", "node-2", "node-3"].map(JSONValue.string)))
    #expect(try f.context.store.list().records.isEmpty)
    #expect(f.context.manager.segments.list().isEmpty)
    #expect(FleetStore(home: f.context.home).list().isEmpty)
  }

  @Test func aFailedMemberIsListedWithItsError() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    f.backend.fail(.start)
    let created = try await f.call([
      "action": .string("create"), "name": .string("web"), "count": .number(2),
      "requirements": VMCreateHandlerTests.Fixture.requirements, "allowUnverified": .bool(true),
    ])
    let members = try #require(created["members"]?.arrayValue)
    #expect(members.count == 2)
    let failed = members.filter { $0["error"] != nil }
    #expect(failed.count == 1, "\(members)")
    #expect(failed.first?["error"]?["code"] == .string("engine_error"))
    _ = try await f.call(["action": .string("destroy"), "name": .string("web")])
    #expect(try f.context.store.list().records.isEmpty)
  }

  @Test func budgetIsCheckedForTheWholeFleet() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    await #expect {
      try await f.call([
        "action": .string("create"), "name": .string("big"), "count": .number(20),
        "requirements": VMCreateHandlerTests.Fixture.requirements,
        "allowUnverified": .bool(true),
      ])
    } throws: { ($0 as? VMLabError)?.code == .limitMemory }
    #expect(try f.context.store.list().records.isEmpty)
    #expect(FleetStore(home: f.context.home).list().isEmpty)
  }

  /// CX-10: a huge count is refused before any member name is built.
  @Test func aHugeCountIsRefusedFirst() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    for count in [1_000_000_000_000, 0, -3, 65] {
      let error = await #expect(throws: VMLabError.self) {
        try await f.call([
          "action": .string("create"), "name": .string("big"), "count": .number(Double(count)),
          "requirements": VMCreateHandlerTests.Fixture.requirements,
          "allowUnverified": .bool(true),
        ])
      }
      #expect(error?.data["field"] == .string("count"), "\(count)")
    }
    #expect(FleetPlanning.memberNames("x", count: Int.max).count == FleetPlanning.maxMembers)
  }

  /// CX-6: destroy never forces: a member whose disk backs a VM outside the fleet is kept and
  /// reported with its refusal; the clone still boots. Once the clone is gone, destroy finishes.
  @Test func destroyKeepsAMemberAnOutsideCloneReadsAndSaysWhy() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.call([
      "action": .string("create"), "name": .string("node"), "count": .number(2),
      "requirements": VMCreateHandlerTests.Fixture.requirements, "allowUnverified": .bool(true),
    ])
    try await f.context.manager.perform(.stop, on: "node-1")
    let outside = try await f.context.manager.clone("node-1", name: "outside")
    let result = try await ToolHandlers.call(
      "fleet", arguments: .object(["action": .string("destroy"), "name": .string("node")]),
      context: f.context)
    #expect(result.value["destroyed"] == .array([.string("node-2")]))
    let failed = try #require(result.value["failed"]?.arrayValue)
    #expect(failed.map { $0["vm"] } == [.string("node-1")])
    #expect(failed.first?["error"]?["data"]?["field"] == .string("force"))
    #expect(result.warnings.contains { $0.contains("node-1") })
    #expect(try f.context.store.find("node-1").name == "node-1")
    #expect(try f.context.store.find(outside.id).name == "outside")

    try await f.context.manager.perform(.destroy, on: outside.id)
    let rest = try await f.call(["action": .string("destroy"), "name": .string("node")])
    #expect(rest["destroyed"] == .array([.string("node-1")]))
    #expect(rest["failed"] == .array([]))
    #expect(try f.context.store.list().records.isEmpty)
  }

  @Test func netSegmentCreateListDestroy() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    func call(_ arguments: [String: JSONValue]) async throws(VMLabError) -> JSONValue {
      try await ToolHandlers.call("net_segment", arguments: .object(arguments), context: f.context)
        .value
    }
    let made = try await call(["action": .string("create"), "name": .string("lab")])
    #expect(made["subnet"] == .string("10.1.0.0/24"))
    #expect(made["running"] == .bool(true))
    let list = try await call(["action": .string("list")])
    #expect(list["segments"]?.arrayValue?.map { $0["name"] } == [.string("lab")])
    let gone = try await call(["action": .string("destroy"), "name": .string("lab")])
    #expect(gone["destroyed"] == .bool(true))
    #expect(f.context.manager.segments.list().isEmpty)
  }
}

extension FleetHandlerTests {
  /// R-904: a command on every member (or a subset) in parallel, a map of results and
  /// `allSucceeded`; a stopped member's refusal is its result, and the flag goes false.
  @Test func execRunsOnEveryMemberOrASubset() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.call([
      "action": .string("create"), "name": .string("node"), "count": .number(3),
      "requirements": VMCreateHandlerTests.Fixture.requirements, "allowUnverified": .bool(true),
    ])
    let all = try await f.call([
      "action": .string("exec"), "name": .string("node"), "command": .string("hostname"),
      "timeoutSeconds": .number(30),
    ])
    #expect(all["allSucceeded"] == .bool(true))
    let results = try #require(all["results"]?.objectValue)
    #expect(results.keys.sorted() == ["node-1", "node-2", "node-3"])
    #expect(results["node-2"]?["stdout"] == .string("hostname\n"))

    let some = try await f.call([
      "action": .string("exec"), "name": .string("node"), "command": .string("true"),
      "members": .array([.string("node-3")]),
    ])
    #expect(some["results"]?.objectValue?.keys.sorted() == ["node-3"])

    try await f.context.manager.perform(.stop, on: "node-1")
    let partial = try await f.call([
      "action": .string("exec"), "name": .string("node"), "command": .string("true"),
    ])
    #expect(partial["allSucceeded"] == .bool(false))
    #expect(partial["results"]?["node-1"]?["error"]?["code"] == .string("wrong_state"))

    await #expect {
      try await f.call([
        "action": .string("exec"), "name": .string("node"), "command": .string("true"),
        "members": .array([.string("node-9")]),
      ])
    } throws: { ($0 as? VMLabError)?.data["field"] == .string("members") }
    _ = try await f.call(["action": .string("destroy"), "name": .string("node")])
  }
}
