import Foundation
import Testing
import VMLabCore

/// R-800: the checkpoint tree in `checkpoints.json`, driven through `VMManager` with the fake
/// backend's state-aware provider (QEMU's contract: live while running, disk while stopped).
@Suite struct CheckpointsTests {
  typealias Fixture = VMManagerTests.Fixture

  static let disk: [Feature] = [.serial, .checkpointDisk]
  static let live: [Feature] = [.serial, .checkpointDisk, .checkpointLive]

  @Test func diskCheckpointsOfAStoppedGuestFormATree() async throws {
    let f = try Fixture()
    let vm = try await f.create(Self.disk)
    let a = try await f.manager.createCheckpoint("web", name: "A", note: "fresh")
    #expect(a.node.mode == .disk)
    #expect(a.node.parent == nil)
    #expect(a.node.state == .created)
    #expect(a.node.note == "fresh")
    #expect(a.node.id.hasPrefix("cp-"))
    #expect(a.warnings.isEmpty)
    let b = try await f.manager.createCheckpoint("web", name: "B")
    #expect(b.node.parent == a.node.id)

    var tree = try await f.manager.checkpoints(of: "web")
    #expect(tree.current == b.node.id)
    #expect(tree.nodes.map(\.name) == ["A", "B"])
    #expect(f.backend.snapshots.snapshots.map(\.id) == [a.node.id, b.node.id])
    #expect(FileManager.default.fileExists(atPath: f.store.checkpointsURL(of: vm.id).path))
    #expect(try f.store.load(id: vm.id).checkpoints.map(\.name) == ["A", "B"])

    // Restore A: it becomes current, and the next checkpoint is its child, a sibling of B.
    let restored = try await f.manager.restoreCheckpoint("web", name: "A")
    #expect(restored.node.id == a.node.id)
    #expect(f.backend.snapshots.restored == [a.node.id])
    let c = try await f.manager.createCheckpoint("web", name: "C")
    #expect(c.node.parent == a.node.id)
    tree = try await f.manager.checkpoints(of: "web")
    #expect(tree.current == c.node.id)
    #expect(try tree.resolve("@latest").id == c.node.id)
    #expect(Set(tree.children(of: a.node.id).map(\.name)) == ["B", "C"])
    #expect(try await f.events(vm.id).contains { $0.hasPrefix("checkpoint restored: A") })
  }

  @Test func namesAreUniqueAndValid() async throws {
    let f = try Fixture()
    _ = try await f.create(Self.disk)
    _ = try await f.manager.createCheckpoint("web", name: "A")
    for name in ["A", "@latest", "", "has space"] {
      let error = await #expect(throws: VMLabError.self) {
        try await f.manager.createCheckpoint("web", name: name)
      }
      #expect(error?.code == .invalidRequest)
      #expect(error?.data["field"] == .string("name"))
    }
    let missing = await #expect(throws: VMLabError.self) {
      try await f.manager.restoreCheckpoint("web", name: "nope")
    }
    #expect(missing?.code == .invalidRequest)
  }

  @Test func autoPicksLiveOnlyWhenGrantedAndRunning() async throws {
    let f = try Fixture()
    _ = try await f.create(Self.live)
    _ = try await f.manager.perform(.start, on: "web")
    let running = try await f.manager.createCheckpoint("web", name: "hot")
    #expect(running.node.mode == .live)
    #expect(running.node.state == .running)
    // Explicit disk while running: the engine refuses, nothing is stopped for us.
    let disk = await #expect(throws: VMLabError.self) {
      try await f.manager.createCheckpoint("web", name: "cold", mode: .disk)
    }
    #expect(disk?.code == .wrongState)
    #expect(try f.store.find("web").state == .running)
    _ = try await f.manager.perform(.stop, on: "web")
    #expect(try await f.manager.createCheckpoint("web", name: "cold").node.mode == .disk)
    let live = await #expect(throws: VMLabError.self) {
      try await f.manager.createCheckpoint("web", name: "x", mode: .live)
    }
    #expect(live?.code == .wrongState)
    // Restoring the live checkpoint needs the guest running.
    let restore = await #expect(throws: VMLabError.self) {
      try await f.manager.restoreCheckpoint("web", name: "hot")
    }
    #expect(restore?.code == .wrongState)
    #expect(try await f.manager.checkpoints(of: "web").nodes.count == 2)
  }

  @Test func runningWithoutCheckpointLiveIsWrongState() async throws {
    let f = try Fixture()
    _ = try await f.create(Self.disk)
    _ = try await f.manager.perform(.start, on: "web")
    let error = await #expect(throws: VMLabError.self) {
      try await f.manager.createCheckpoint("web", name: "A")
    }
    #expect(error?.code == .wrongState)
    #expect(error?.hint.contains("vm_lifecycle stop") == true)
    #expect(error?.data["state"] == .string("running"))
    #expect(try f.store.find("web").state == .running)
    let live = await #expect(throws: VMLabError.self) {
      try await f.manager.createCheckpoint("web", name: "A", mode: .live)
    }
    #expect(live?.code == .capabilityMissing)
    #expect(live?.data["feature"] == .string("checkpoint_live"))
  }

  @Test func aPlanWithoutCheckpointsIsCapabilityMissing() async throws {
    let f = try Fixture()
    _ = try await f.create([.serial])
    let error = await #expect(throws: VMLabError.self) {
      try await f.manager.createCheckpoint("web", name: "A")
    }
    #expect(error?.code == .capabilityMissing)
  }

  @Test func deleteRefusesChildrenUnlessRecursive() async throws {
    let f = try Fixture()
    _ = try await f.create(Self.disk)
    let a = try await f.manager.createCheckpoint("web", name: "A").node
    let b = try await f.manager.createCheckpoint("web", name: "B").node
    let c = try await f.manager.createCheckpoint("web", name: "C").node
    let refused = await #expect(throws: VMLabError.self) {
      try await f.manager.deleteCheckpoint("web", name: "A")
    }
    #expect(refused?.code == .invalidRequest)
    #expect(refused?.data["field"] == .string("recursive"))

    // A leaf goes alone; current passes to its parent.
    #expect(try await f.manager.deleteCheckpoint("web", name: "C").map(\.id) == [c.id])
    #expect(try await f.manager.checkpoints(of: "web").current == b.id)
    let deleted = try await f.manager.deleteCheckpoint("web", name: "A", recursive: true)
    #expect(deleted.map(\.id) == [b.id, a.id])
    let tree = try await f.manager.checkpoints(of: "web")
    #expect(tree.nodes.isEmpty)
    #expect(tree.current == nil)
    #expect(f.backend.snapshots.ids.isEmpty)
    #expect(try f.store.find("web").checkpoints.isEmpty)
  }

  @Test func manifestIsAHookUntilR801() async throws {
    let f = try Fixture()
    _ = try await f.create(Self.disk)
    let without = try await f.manager.createCheckpoint("web", name: "A", manifest: true)
    #expect(without.node.manifestPath == nil)
    #expect(without.warnings.count == 1)

    let registry = BackendRegistry()
    registry.register(f.backend)
    let manager = VMManager(store: f.store, backends: registry, manifests: FixedManifests())
    let with = try await manager.createCheckpoint("web", name: "B", manifest: true)
    #expect(with.node.manifestPath == "/manifests/\(with.node.id).json")
    #expect(with.warnings.isEmpty)
    let plain = try await manager.createCheckpoint("web", name: "C")
    #expect(plain.node.manifestPath == nil)
  }

  @Test func checkpointStopSuspendsAndStartResumes() async throws {
    let f = try Fixture()
    let vm = try await f.create(Self.live)
    _ = try await f.manager.perform(.start, on: "web")
    let suspended = try #require(try await f.manager.perform(.checkpointStop, on: "web"))
    #expect(suspended.state == .suspended)
    #expect(suspended.runtime == nil)
    var tree = try await f.manager.checkpoints(of: "web")
    let resume = try #require(tree.resume)
    let saved = try #require(tree.node(id: resume))
    #expect(saved.temporary)
    #expect(saved.mode == .live)
    #expect(f.backend.operations.suffix(1) == [.kill])

    // A suspended VM must be started before any other checkpoint work.
    let refused = await #expect(throws: VMLabError.self) {
      try await f.manager.createCheckpoint("web", name: "A")
    }
    #expect(refused?.code == .wrongState)
    let pinned = await #expect(throws: VMLabError.self) {
      try await f.manager.deleteCheckpoint("web", name: saved.name)
    }
    #expect(pinned?.code == .wrongState)

    let running = try #require(try await f.manager.perform(.start, on: vm.id))
    #expect(running.state == .running)
    #expect(f.backend.snapshots.restored == [saved.id])
    tree = try await f.manager.checkpoints(of: "web")
    #expect(tree.resume == nil)
    #expect(tree.current == saved.id)
  }

  @Test func checkpointStopNeedsCheckpointLive() async throws {
    let f = try Fixture()
    _ = try await f.create(Self.disk)
    _ = try await f.manager.perform(.start, on: "web")
    let error = await #expect(throws: VMLabError.self) {
      try await f.manager.perform(.checkpointStop, on: "web")
    }
    #expect(error?.code == .capabilityMissing)
    #expect(try f.store.find("web").state == .running)
  }

  @Test func treeRoundTripsAndOldNodesDecode() throws {
    let json = """
      {"schemaVersion":1,"current":"cp-aaaaaa","nodes":[{"id":"cp-aaaaaa","name":"A","mode":"disk",
      "createdAt":"2026-10-18T10:00:00Z","state":"stopped"}]}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let tree = try decoder.decode(CheckpointTree.self, from: Data(json.utf8))
    #expect(tree.nodes.first?.temporary == false)
    #expect(tree.current == "cp-aaaaaa")
    #expect(tree.json["nodes"]?.arrayValue?.first?["parent"] == nil)
  }
}

struct FixedManifests: GuestManifestTaker {
  func take(_ record: VMRecord, checkpoint: String) async throws(VMLabError) -> String {
    "/manifests/\(checkpoint).json"
  }
}
