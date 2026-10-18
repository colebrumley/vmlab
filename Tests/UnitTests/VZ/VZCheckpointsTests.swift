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

  /// A file operation that fails on its `failOn`th call (1-based) and runs `then` otherwise.
  final class FailingOn: @unchecked Sendable {
    let failOn: Int
    var calls = 0
    init(_ failOn: Int) { self.failOn = failOn }
    func tick() throws {
      calls += 1
      if calls == failOn { throw POSIXError(.ENOSPC) }
    }
  }

  /// A restore whose copy fails partway (a non-APFS home that is out of space) leaves every live
  /// file as it was: nothing is deleted before all the copies exist.
  @Test(arguments: [1, 2, 3])
  func aFailedCopyLeavesTheLiveFilesIntact(failOn: Int) async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await f.provider().create(id: "cp-eeeeee", mode: .disk)
    for name in VZCheckpoints.clonedFiles {
      try Data("\(name) v2".utf8).write(to: f.dir.appending(path: name))
    }
    let failing = FailingOn(failOn)
    let ops = VZCheckpoints.FileOps(
      copy: { from, to in
        try failing.tick()
        try VZCheckpoints.FileOps.system.copy(from, to)
      }, exchange: VZCheckpoints.FileOps.system.exchange)
    let folder = VZCheckpoints.directory(of: "cp-eeeeee", vmDirectory: f.dir)
    #expect(throws: VMLabError.self) {
      try VZCheckpoints.load(f.provider().files, from: folder, using: ops)
    }
    for name in VZCheckpoints.clonedFiles {
      #expect(try f.file(name) == "\(name) v2")
    }
    #expect(try leftovers(in: f.dir).isEmpty)
  }

  /// A rename that fails partway rolls back the ones already made: the VM never mixes the
  /// checkpoint's disk with its current EFI variables.
  @Test(arguments: [1, 2, 3])
  func aFailedRenameRollsBack(failOn: Int) async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await f.provider().create(id: "cp-ffffff", mode: .disk)
    for name in VZCheckpoints.clonedFiles {
      try Data("\(name) v2".utf8).write(to: f.dir.appending(path: name))
    }
    let failing = FailingOn(failOn)
    let ops = VZCheckpoints.FileOps(
      copy: VZCheckpoints.FileOps.system.copy,
      exchange: { a, b in
        // Only the forward renames count; the rollback must work.
        if a.lastPathComponent.contains(".vmlab-new-") { try failing.tick() }
        try VZCheckpoints.FileOps.system.exchange(a, b)
      })
    let folder = VZCheckpoints.directory(of: "cp-ffffff", vmDirectory: f.dir)
    #expect(throws: VMLabError.self) {
      try VZCheckpoints.load(f.provider().files, from: folder, using: ops)
    }
    for name in VZCheckpoints.clonedFiles {
      #expect(try f.file(name) == "\(name) v2")
    }
    #expect(try leftovers(in: f.dir).isEmpty)
    // And without a failure, every file comes back.
    try VZCheckpoints.load(f.provider().files, from: folder)
    for name in VZCheckpoints.clonedFiles {
      #expect(try f.file(name) == "\(name) v1")
    }
    #expect(try leftovers(in: f.dir).isEmpty)
  }

  /// A restore of a file the VM does not have yet creates it.
  @Test func restoreCreatesAMissingLiveFile() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await f.provider().create(id: "cp-gggggg", mode: .disk)
    try FileManager.default.removeItem(at: f.dir.appending(path: "machine-id.bin"))
    try await f.provider().restore(id: "cp-gggggg", mode: .disk)
    #expect(try f.file("machine-id.bin") == "machine-id.bin v1")
    #expect(try leftovers(in: f.dir).isEmpty)
  }

  func leftovers(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".vmlab-") }
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

  /// A vz-macos guest's checkpoint clones its Tart clone's disk and auxiliary storage.
  @Test func macOSGuestsCloneTheirTartFiles() {
    var record = VMRecord(
      id: "vm-mac001", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      features: [.checkpointLive])
    record.tartClone = "/Users/me/.tart/vms/vm-mac001"
    let files = VZCheckpoints.stateFiles(of: record, vmDirectory: URL(filePath: "/vm"))
    #expect(files.map(\.name) == ["disk.img", "nvram.bin"])
    #expect(
      files.map(\.live.path) == [
        "/Users/me/.tart/vms/vm-mac001/disk.img", "/Users/me/.tart/vms/vm-mac001/nvram.bin",
      ])
  }
}
