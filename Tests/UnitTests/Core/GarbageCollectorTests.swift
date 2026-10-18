import Foundation
import Synchronization
import Testing
import VMLabCore

/// R-805: `vmlab gc` over a fixture home, and the backing-chain refusal of `destroy`.
@Suite struct GarbageCollectorTests {
  typealias Fixture = VMManagerTests.Fixture

  static let old = Date().addingTimeInterval(-8 * 24 * 3600)

  static func write(_ url: URL, bytes: Int = 4096, modified: Date? = nil) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: bytes).write(to: url)
    if let modified {
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
  }

  /// Pid 4242 is a live QEMU, 4343 a live process that is not an engine.
  final class Processes: Sendable {
    let terminated = Mutex<[Int32]>([])
    var inspector: ProcessInspector {
      ProcessInspector(
        isAlive: { $0 == 4242 || $0 == 4343 },
        executablePath: {
          $0 == 4242 ? "/opt/homebrew/bin/qemu-system-aarch64" : $0 == 4343 ? "/bin/sleep" : nil
        },
        terminate: { pid in self.terminated.withLock { $0.append(pid) } })
    }
  }

  /// A stale pid file in an orphaned directory whose pid was reused by another VM's engine names
  /// that engine: gc removes the directory but kills only the engine whose arguments lie in it.
  @Test func killsAnOrphansEngineOnlyWhenItRunsThatDirectory() async throws {
    let f = try Fixture()
    let stale = f.store.vmsDirectory.appending(path: "vm-stale0")
    let orphan = f.store.vmsDirectory.appending(path: "vm-orphan")
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    // 4242 is another VM's QEMU; 4444 is the orphan's own runner.
    try "4242\n".write(to: stale.appending(path: "qemu.pid"), atomically: true, encoding: .utf8)
    try "4444\n".write(to: orphan.appending(path: "vz.pid"), atomically: true, encoding: .utf8)
    for directory in [stale, orphan] {
      try FileManager.default.setAttributes(
        [.modificationDate: Self.old], ofItemAtPath: directory.path)
    }
    let other = f.store.vmsDirectory.appending(path: "vm-other0")
    let terminated = Mutex<[Int32]>([])
    var collector = GarbageCollector(manager: f.manager)
    collector.processes = ProcessInspector(
      isAlive: { $0 == 4242 || $0 == 4444 },
      executablePath: {
        $0 == 4242
          ? "/opt/homebrew/bin/qemu-system-aarch64" : $0 == 4444 ? "/usr/local/bin/vmlab-vz" : nil
      },
      terminate: { pid in terminated.withLock { $0.append(pid) } },
      runsVM: { pid, directory in
        directory.lastPathComponent == (pid == 4242 ? other : orphan).lastPathComponent
      })

    let report = await collector.run()
    #expect(terminated.withLock { $0 } == [4444])
    let processes = report.items.filter { $0.kind == .orphanProcess }
    #expect(processes.map(\.vm) == ["vm-orphan"])
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
  }

  /// CX-14: an engine still running for a record with no runtime is collected (unless the VM's
  /// lock is held); one for a record that has a runtime is that VM's and stays.
  @Test func collectsAnEngineARecordWithoutRuntimeLeft() async throws {
    let f = try Fixture()
    let stranded = try await f.create()
    try "4242\n".write(
      to: f.store.directory(of: stranded.id).appending(path: "qemu.pid"), atomically: true,
      encoding: .utf8)
    let processes = Processes()
    var collector = GarbageCollector(manager: f.manager)
    collector.processes = processes.inspector
    collector.processes.runsVM = { pid, _ in pid == 4242 }

    let held = try #require(FileLock.tryLock(f.store.operationLockPath(of: stranded.id)))
    #expect(await collector.run().items.filter { $0.kind == .orphanProcess }.isEmpty)
    held.unlock()

    let report = await collector.run()
    #expect(report.items.contains { $0.kind == .orphanProcess && $0.vm == stranded.id })
    #expect(processes.terminated.withLock { $0 } == [4242])

    _ = try await f.manager.perform(.start, on: stranded.id)
    processes.terminated.withLock { $0 = [] }
    _ = await collector.run()
    #expect(processes.terminated.withLock { $0 }.isEmpty)
  }

  @Test func collectsEverythingTheItemNamesAndNothingElse() async throws {
    let f = try Fixture()
    let source = try await f.create([.serial, .checkpointDisk, .checkpointLive])
    let dir = f.store.directory(of: source.id)

    // Dumps and exec logs: old ones go, new ones and job records stay.
    try Self.write(dir.appending(path: "dumps/old.raw"), modified: Self.old)
    try Self.write(dir.appending(path: "dumps/new.raw"))
    try Self.write(dir.appending(path: "exec/job-1.log"), modified: Self.old)
    try Self.write(dir.appending(path: "exec/job-1.json"), modified: Self.old)
    try Self.write(dir.appending(path: "exec/job-2.log"))

    // An orphaned QEMU (record gone), and an orphan whose pid is some other program.
    let orphan = f.store.vmsDirectory.appending(path: "vm-orphan")
    try Self.write(orphan.appending(path: "qemu.pid"), bytes: 0)
    try "4242\n".write(to: orphan.appending(path: "qemu.pid"), atomically: true, encoding: .utf8)
    let stray = f.store.vmsDirectory.appending(path: "vm-stray1")
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
    try "4343\n".write(to: stray.appending(path: "vz.pid"), atomically: true, encoding: .utf8)
    for directory in [orphan, stray] {
      try FileManager.default.setAttributes(
        [.modificationDate: Self.old], ofItemAtPath: directory.path)
    }

    // A temporary checkpoint (a resumed checkpoint_stop) and a kept one as its child.
    _ = try await f.manager.perform(.start, on: source.id)
    _ = try await f.manager.perform(.checkpointStop, on: source.id)
    _ = try await f.manager.perform(.start, on: source.id)
    let kept = try await f.manager.createCheckpoint(source.id, name: "kept").node

    // Backing files: one a clone reads, one nobody reads, one too young to judge.
    _ = try await f.manager.perform(.stop, on: source.id)
    let clone = try await f.manager.clone(source.id, name: "copy")
    let used = try #require(clone.backingChain?.first)
    try Self.write(URL(filePath: used), modified: Self.old)
    let unused = dir.appending(path: "backing/cp-gone00.qcow2")
    try Self.write(unused, bytes: 8192, modified: Self.old)
    let young = dir.appending(path: "backing/disk-vm-fresh0.qcow2")
    try Self.write(young)

    let processes = Processes()
    var collector = GarbageCollector(manager: f.manager)
    collector.processes = processes.inspector
    collector.processes.runsVM = { pid, directory in pid == 4242 && directory == orphan }

    collector.dryRun = true
    let preview = await collector.run()
    #expect(preview.dryRun)
    #expect(FileManager.default.fileExists(atPath: unused.path))
    #expect(processes.terminated.withLock { $0 }.isEmpty)

    collector.dryRun = false
    let report = await collector.run()
    #expect(report.errors.isEmpty, "\(report.errors)")
    #expect(report.items.map(\.kind) == preview.items.map(\.kind))
    let byKind = Dictionary(grouping: report.items, by: \.kind)
    #expect(byKind[.orphanProcess]?.map(\.vm) == ["vm-orphan"])
    #expect(processes.terminated.withLock { $0 } == [4242])
    #expect(Set(byKind[.orphanDirectory]?.compactMap(\.vm) ?? []) == ["vm-orphan", "vm-stray1"])
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(byKind[.dump]?.map(\.target) == [dir.appending(path: "dumps/old.raw").path])
    #expect(byKind[.execLog]?.map(\.target) == [dir.appending(path: "exec/job-1.log").path])
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "exec/job-1.json").path))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "dumps/new.raw").path))
    #expect(byKind[.temporaryCheckpoint]?.count == 1)
    #expect(byKind[.backingFile]?.map(\.target) == [unused.path])
    #expect(FileManager.default.fileExists(atPath: used))
    #expect(FileManager.default.fileExists(atPath: young.path))
    #expect(report.bytesFreed >= 8192 + 4096 * 2)

    // The kept checkpoint moved up to the root; the clone and the source are untouched.
    let tree = try f.store.checkpoints(of: source.id)
    #expect(tree.nodes.map(\.id) == [kept.id])
    #expect(tree.nodes.first?.parent == nil)
    #expect(try f.store.list().records.count == 2)

    // A second run finds nothing.
    let again = await collector.run()
    #expect(again.items.isEmpty)
  }

  /// A template no VM was created from or reads through, unchanged for a week, goes; one a VM
  /// names, one a backing chain reads, a young one and a plain pulled image stay.
  @Test func collectsUnusedTemplates() async throws {
    let f = try Fixture()
    let vm = try await f.create()
    let images = ImageStore(home: f.store.home)
    func image(_ name: String, template: Bool, modified: Date? = Self.old) throws -> URL {
      let directory = images.imageDirectory(name)
      try Self.write(directory.appending(path: "disk.qcow2"), bytes: 8192)
      let pulled = PulledImage(
        name: name, guest: GuestSpec(os: .linux, arch: .arm64),
        source: template ? "template:vm-src001" : "fixture", format: .qcow2, checksum: nil,
        files: ["qcow2": "disk.qcow2"], login: ImageLogin(user: "debian"), pulledAt: Date(),
        template: template
          ? TemplateInfo(
            sourceVM: "vm-src001", sourceName: "src", baseImage: "debian-13-arm64",
            revokedKeys: [], provisioned: [], createdAt: Date()) : nil)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let json = directory.appending(path: "image.json")
      try encoder.encode(pulled).write(to: json)
      if let modified {
        try FileManager.default.setAttributes(
          [.modificationDate: modified], ofItemAtPath: json.path)
      }
      return directory
    }
    let unused = try image("tpl-unused", template: true)
    let named = try image("tpl-named", template: true)
    let read = try image("tpl-read", template: true)
    let young = try image("tpl-young", template: true, modified: nil)
    let plain = try image("plain-image", template: false)
    try f.store.update(id: vm.id) {
      $0.image = "tpl-named"
      $0.backingChain = [read.appending(path: "disk.qcow2").path]
    }

    var collector = GarbageCollector(manager: f.manager)
    collector.processes = Processes().inspector
    let report = await collector.run()
    #expect(report.errors.isEmpty, "\(report.errors)")
    let templates = report.items.filter { $0.kind == .templateImage }
    #expect(templates.map(\.target) == [unused.path])
    #expect((templates.first?.bytes ?? 0) >= 8192)
    #expect(!FileManager.default.fileExists(atPath: unused.path))
    for kept in [named, read, young, plain] {
      #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent)")
    }
  }

  @Test func destroyRefusesWhileAnotherDiskDependsOnItUnlessForced() async throws {
    let f = try Fixture()
    let source = try await f.create([.serial, .checkpointDisk])
    let clone = try await f.manager.clone(source.id, name: "copy")
    let refused = await #expect(throws: VMLabError.self) {
      try await f.manager.perform(.destroy, on: source.id)
    }
    #expect(refused?.code == .invalidRequest)
    #expect(refused?.data["field"] == .string("force"))
    #expect(refused?.data["dependents"] == .array([.string(clone.id)]))
    #expect(try f.store.find(source.id).state == .created)

    let forced = try await f.manager.run(.destroy, on: source.id, force: true)
    #expect(forced.record == nil)
    #expect(forced.warnings.contains { $0.contains(clone.id) })
    #expect(throws: VMLabError.self) { try f.store.find(source.id) }

    // A VM nothing depends on is destroyed without force, the clone included.
    #expect(try await f.manager.perform(.destroy, on: clone.id) == nil)
  }
}
