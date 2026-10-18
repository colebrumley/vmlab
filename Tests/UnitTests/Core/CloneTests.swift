import Foundation
import Testing
import VMLabCore

/// R-803: `VMManager.clone` with the fake backend.
@Suite struct CloneTests {
  typealias Fixture = VMManagerTests.Fixture

  @Test func cloneOfTheCurrentDiskKeepsThePlanWithANewIdentity() async throws {
    let f = try Fixture()
    let source = try await f.create([.serial, .execSSH, .checkpointDisk])
    let clone = try await f.manager.clone("web", name: "web-2")
    #expect(clone.id != source.id)
    #expect(clone.name == "web-2")
    #expect(clone.state == .created)
    #expect(clone.features == source.features)
    #expect(clone.plan == source.plan)
    #expect(clone.image == source.image)
    #expect(clone.checkpoints.isEmpty)
    #expect(clone.clonedFrom?.vm == source.id)
    #expect(clone.clonedFrom?.checkpoint == nil)
    let chain = try #require(clone.backingChain)
    #expect(
      chain == [
        f.store.directory(of: source.id).appending(path: "backing/disk-\(clone.id).qcow2").path
      ])
    // A key of its own.
    let key = SSHKeys.publicKey(in: f.store.directory(of: clone.id))
    let sourceKey = SSHKeys.publicKey(in: f.store.directory(of: source.id))
    #expect(
      try String(contentsOf: key, encoding: .utf8) != String(contentsOf: sourceKey, encoding: .utf8)
    )
    #expect(try f.manager.dependents(of: source).map(\.id) == [clone.id])
    #expect(try f.manager.dependents(of: clone).isEmpty)
    #expect(try await f.events(clone.id).contains { $0.hasPrefix("cloned from \(source.id)") })
  }

  @Test func aRunningSourceClonesOnlyFromACheckpoint() async throws {
    let f = try Fixture()
    _ = try await f.create([.serial, .checkpointDisk, .checkpointLive])
    _ = try await f.manager.perform(.start, on: "web")
    let refused = await #expect(throws: VMLabError.self) {
      try await f.manager.clone("web", name: "copy")
    }
    #expect(refused?.code == .wrongState)
    #expect(refused?.hint.contains("checkpoint") == true)
    let cp = try await f.manager.createCheckpoint("web", name: "A").node
    let clone = try await f.manager.clone("web", name: "copy", from: "A")
    #expect(clone.clonedFrom?.checkpoint == cp.id)
    #expect(clone.clonedFrom?.checkpointName == "A")
    #expect(clone.backingChain?.first?.hasSuffix("backing/\(cp.id).qcow2") == true)
    #expect(try f.store.find("web").state == .running)
  }

  @Test func failuresLeaveNoClone() async throws {
    let f = try Fixture()
    _ = try await f.create([.serial, .checkpointDisk])
    let missing = await #expect(throws: VMLabError.self) {
      try await f.manager.clone("web", name: "copy", from: "nope")
    }
    #expect(missing?.code == .invalidRequest)
    let taken = await #expect(throws: VMLabError.self) {
      try await f.manager.clone("web", name: "web")
    }
    #expect(taken?.code == .invalidRequest)
    f.backend.fail(.clone)
    await #expect(throws: VMLabError.self) { try await f.manager.clone("web", name: "copy") }
    #expect(try f.store.list().records.map(\.name) == ["web"])
  }
}
