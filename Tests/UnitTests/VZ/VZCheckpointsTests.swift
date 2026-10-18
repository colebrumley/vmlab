import Foundation
import Testing
import VMLabCore

@testable import VMLabVZ

/// R-608's checkpoint provider without a guest: disk checkpoints of a stopped VM are clones of
/// its files in `checkpoints/<id>/`, and the states a mode cannot serve are refused.
@Suite struct VZCheckpointsTests {
  struct Fixture {
    let home: URL
    let store: Store
    let backend: VZBackend
    let record: VMRecord
    var dir: URL { store.directory(of: record.id) }

    init(state: VMState = .stopped) throws {
      home = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzcp-\(UUID())")
      store = Store(home: home)
      var record = try store.create(
        VMRecord(
          id: "", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
          features: [.checkpointDisk, .checkpointLive]))
      record = try store.update(id: record.id) { $0.state = state }
      self.record = record
      backend = VZBackend(store: store)
      for name in VZCheckpoints.clonedFiles {
        try Data("\(name) v1".utf8).write(to: store.directory(of: record.id).appending(path: name))
      }
    }

    func provider() -> VZCheckpoints { VZCheckpoints(backend: backend, record: record) }
    func file(_ name: String, in folder: URL? = nil) throws -> String {
      String(decoding: try Data(contentsOf: (folder ?? dir).appending(path: name)), as: UTF8.self)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: home) }
  }

  @Test func diskCheckpointClonesAndRestoresTheFiles() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let provider = f.provider()
    try await provider.create(id: "cp-aaaaaa", mode: .disk)
    let folder = VZCheckpoints.directory(of: "cp-aaaaaa", vmDirectory: f.dir)
    for name in VZCheckpoints.clonedFiles {
      #expect(try f.file(name, in: folder) == "\(name) v1")
      try Data("\(name) v2".utf8).write(to: f.dir.appending(path: name))
    }
    try await provider.restore(id: "cp-aaaaaa", mode: .disk)
    #expect(try f.file("disk.raw") == "disk.raw v1")
    #expect(try f.file("efi-vars.bin") == "efi-vars.bin v1")

    await #expect {
      try await provider.create(id: "cp-aaaaaa", mode: .disk)
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    try await provider.delete(id: "cp-aaaaaa")
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    await #expect {
      try await provider.delete(id: "cp-aaaaaa")
    } throws: { ($0 as? VMLabError)?.data["field"] == .string("id") }
  }

  @Test func diskModeRefusesARunningGuest() async throws {
    let f = try Fixture(state: .running)
    defer { f.cleanUp() }
    await #expect {
      try await f.provider().create(id: "cp-bbbbbb", mode: .disk)
    } throws: { ($0 as? VMLabError)?.code == .wrongState }
    #expect(
      !FileManager.default.fileExists(
        atPath: VZCheckpoints.directory(of: "cp-bbbbbb", vmDirectory: f.dir).path))
  }

  @Test func liveModeNeedsALiveGuestAndASavedState() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    // No runner answers: a live create cannot reach the guest.
    await #expect {
      try await f.provider().create(id: "cp-cccccc", mode: .live)
    } throws: { ($0 as? VMLabError)?.code == .guestUnreachable }
    try await f.provider().create(id: "cp-dddddd", mode: .disk)
    await #expect {
      try await f.provider().restore(id: "cp-dddddd", mode: .live)
    } throws: { ($0 as? VMLabError)?.code == .wrongState }
  }

  @Test func backendHandsOutTheProviderInAnyState() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    #expect(try await f.backend.checkpoints(f.record) is VZCheckpoints)
  }
}
