import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

/// R-803: QEMU clones of a stopped guest with the host's `qemu-img` (skipped without QEMU): the
/// clone is an overlay over a frozen layer in the source's `backing/`, which holds the current
/// disk or the checkpoint's contents; the source is untouched.
@Suite struct QEMUCloneTests {
  static let installation = try? QEMUInstallation.locate()
  static var qemuIO: URL? { installation?.binDirectory.appending(path: "qemu-io") }
  static var ready: Bool {
    guard let io = qemuIO, let installation else { return false }
    return FileManager.default.isExecutableFile(atPath: installation.qemuImg.path)
      && FileManager.default.isExecutableFile(atPath: io.path)
  }

  struct Fixture {
    let home: URL
    let store: Store
    let backend: QEMUBackend
    let source: VMRecord
    let base: URL

    init() throws {
      home = FileManager.default.temporaryDirectory.appending(path: "vmlab-clone-\(UUID())")
      store = Store(home: home)
      let installation = try #require(QEMUCloneTests.installation)
      backend = QEMUBackend(profile: .qemuHVF, store: store, installation: installation)
      source = try store.create(
        VMRecord(
          id: "", name: "src", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
          features: [.checkpointDisk], image: "tiny", state: .stopped))
      base = home.appending(path: "base.qcow2")
      try Self.img(["create", "-q", "-f", "qcow2", base.path, "1M"])
      try Self.img([
        "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", base.path,
        backend.layout(of: source.id).disk.path,
      ])
    }

    func target(_ name: String) throws -> VMRecord {
      var draft = source
      draft.name = name
      return try store.create(draft)
    }

    static func img(_ arguments: [String]) throws {
      let tool = try #require(QEMUCloneTests.installation).qemuImg.path
      let result = try #require(ProcessRunner().run(tool, arguments))
      #expect(result.status == 0, "\(result.output)")
    }

    /// Writes `pattern` over the first 64 KB of `disk`, or checks it is there.
    static func io(_ disk: URL, _ op: String, _ pattern: UInt8) throws -> Bool {
      let io = try #require(QEMUCloneTests.qemuIO).path
      let command = "\(op) -P 0x\(String(pattern, radix: 16)) 0 64k"
      let result = try #require(ProcessRunner().run(io, ["-c", command, disk.path]))
      return result.status == 0 && !result.output.contains("Pattern verification failed")
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }
  }

  /// CX-14: a clone that fails (or crashes) after making the frozen layer but before the
  /// manager records the chain left no record of it, and gc deleted the layer under the clone.
  /// The layer is in the clone's backingChain before anything is made.
  @Test(.enabled(if: ready)) func theFrozenLayerIsRecordedBeforeTheOverlay() async throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.home) }
    let target = try f.target("copy")
    // The overlay cannot be made where a directory is.
    try FileManager.default.createDirectory(
      at: f.backend.layout(of: target.id).disk, withIntermediateDirectories: true)
    await #expect(throws: VMLabError.self) {
      _ = try await f.backend.clone(f.source, checkpoint: nil, into: target)
    }
    let frozen = f.backend.layout(of: f.source.id).directory.appending(
      path: "backing/disk-\(target.id).qcow2")
    #expect(FileManager.default.fileExists(atPath: frozen.path))
    #expect(try f.store.load(id: target.id).backingChain == [frozen.path])
  }

  @Test(.enabled(if: ready)) func clonesTheCurrentDiskAndACheckpoint() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let disk = f.backend.layout(of: f.source.id).disk
    #expect(try Fixture.io(disk, "write", 0xab))
    try Fixture.img(["snapshot", "-c", "cp-aaaaaa", disk.path])
    #expect(try Fixture.io(disk, "write", 0xcd))
    let node = CheckpointNode(id: "cp-aaaaaa", name: "A", mode: .disk, state: .stopped)

    let fromCheckpoint = try f.target("a")
    let chain = try await f.backend.clone(f.source, checkpoint: node, into: fromCheckpoint)
    let frozen = f.store.directory(of: f.source.id).appending(path: "backing/cp-aaaaaa.qcow2")
    #expect(chain.map(\.path) == [frozen.path, f.base.path])
    let cloneDisk = f.backend.layout(of: fromCheckpoint.id).disk
    #expect(try Fixture.io(cloneDisk, "read", 0xab))

    let fromDisk = try f.target("b")
    let current = try await f.backend.clone(f.source, checkpoint: nil, into: fromDisk)
    #expect(current.first?.lastPathComponent == "disk-\(fromDisk.id).qcow2")
    #expect(try Fixture.io(f.backend.layout(of: fromDisk.id).disk, "read", 0xcd))

    // Writes to a clone stay in the clone.
    #expect(try Fixture.io(cloneDisk, "write", 0xee))
    #expect(try Fixture.io(disk, "read", 0xcd))
    #expect(
      try QEMUImageSnapshots.tags(try #require(QEMUCloneTests.installation).qemuImg, disk: disk)
        == ["cp-aaaaaa"])

    // A second clone of the checkpoint shares the frozen layer.
    let again = try await f.backend.clone(f.source, checkpoint: node, into: try f.target("c"))
    #expect(again.first == frozen)

    let unknown = CheckpointNode(id: "cp-zzzzzz", name: "Z", mode: .disk, state: .stopped)
    let error = await #expect(throws: VMLabError.self) {
      try await f.backend.clone(f.source, checkpoint: unknown, into: try f.target("d"))
    }
    #expect(error?.code == .invalidRequest)
  }
}
