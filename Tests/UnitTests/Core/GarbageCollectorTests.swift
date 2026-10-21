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
  /// A dump written through `vm_memory_dump`'s `local` lies outside every VM directory: never an
  /// item, however old (R-1205).
  @Test func leavesDumpsOutsideTheVMDirectoryAlone() async throws {
    let f = try Fixture()
    let vm = try await f.create([.serial, .memoryDump])
    let inside = f.store.directory(of: vm.id).appending(path: "dumps/old.raw")
    try Self.write(inside, modified: Self.old)
    let outside = FileManager.default.temporaryDirectory.appending(path: "vmlab-dump-\(UUID())")
    defer { try? FileManager.default.removeItem(at: outside) }
    let dump = outside.appending(path: "old.raw")
    try Self.write(dump, modified: Self.old)
    var collector = GarbageCollector(manager: f.manager)
    collector.processes = Processes().inspector
    let report = await collector.run()
    #expect(report.items.filter { $0.kind == .dump }.map(\.target) == [inside.path])
    #expect(FileManager.default.fileExists(atPath: dump.path))
  }

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

  // MARK: R-1207

  static func age(_ directory: URL, to date: Date) throws {
    let walker = FileManager.default.enumerator(atPath: directory.path)
    while let relative = walker?.nextObject() as? String {
      try FileManager.default.setAttributes(
        [.modificationDate: date], ofItemAtPath: directory.appending(path: relative).path)
    }
    try FileManager.default.setAttributes(
      [.modificationDate: date], ofItemAtPath: directory.path)
  }

  static func writeSegment(_ segments: SegmentStore, _ name: String, members: [String] = [])
    throws
  {
    var segment = Segment(name: name, index: 1, createdAt: Date())
    segment.members = members.map {
      SegmentMember(
        vm: $0, name: $0, address: "10.1.0.10", mac: "52:54:00:00:00:01", joinedAt: Date())
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(
      at: segments.directory(of: name), withIntermediateDirectories: true)
    try encoder.encode(segment).write(to: segments.recordURL(of: name))
  }

  @Test func switchPredicateNamesOnlyTheSwitch() {
    #expect(EngineProcess.isSwitch("/Users/x/vmlab/.build/debug/vmlab-switch"))
    #expect(!EngineProcess.isSwitch("/opt/homebrew/bin/qemu-system-aarch64"))
    #expect(!EngineProcess.isSwitch("/usr/local/bin/vmlab-vz"))
    #expect(!EngineProcess.isEngine("/Users/x/vmlab/.build/debug/vmlab-switch"))
  }

  /// The switch of a segment no VM uses goes; one with a member, one a live VM names, one of
  /// another home stay. A directory with no manifest goes after `grace`, a young one stays, and a
  /// manifest with no switch running is left alone.
  @Test func endsTheSwitchesOfUnusedSegments() async throws {
    let f = try Fixture()
    let segments = f.manager.segments
    let user = try await f.create()
    try f.store.update(id: user.id) {
      $0.state = .running
      $0.segment = SegmentAttachment(
        segment: "live", address: "10.1.0.10", mac: "52:54:00:00:00:02")
    }
    try Self.writeSegment(segments, "idle")
    try Self.writeSegment(segments, "member", members: ["vm-abcdef"])
    try Self.writeSegment(segments, "live")
    try Self.writeSegment(segments, "other")
    try Self.writeSegment(segments, "quiet")
    let pids: [String: Int32] = [
      "idle": 5001, "member": 5002, "live": 5003, "other": 5004, "gone": 5005, "fresh": 5006,
    ]
    for (name, pid) in pids {
      try Self.write(segments.pidFile(of: name), bytes: 0)
      try "\(pid)\n".write(to: segments.pidFile(of: name), atomically: true, encoding: .utf8)
    }
    try Self.age(segments.directory, to: Self.old)
    try Self.write(segments.directory(of: "fresh").appending(path: "switch.log"))

    let terminated = Mutex<[Int32]>([])
    let other = segments.directory(of: "other")
    var collector = GarbageCollector(manager: f.manager)
    collector.processes = ProcessInspector(
      isAlive: { (5001...5006).contains($0) },
      executablePath: { _ in "/Users/x/vmlab/.build/debug/vmlab-switch" },
      terminate: { pid in terminated.withLock { $0.append(pid) } },
      runsVM: { pid, directory in
        // 5004 is the switch of another segment, whose pid file "other" still names.
        pid == 5004
          ? directory != other
          : directory.deletingLastPathComponent().path == segments.directory.path
      })

    collector.dryRun = true
    let preview = await collector.run()
    #expect(terminated.withLock { $0 }.isEmpty)
    #expect(FileManager.default.fileExists(atPath: segments.directory(of: "gone").path))

    collector.dryRun = false
    let report = await collector.run()
    #expect(report.errors.isEmpty, "\(report.errors)")
    #expect(report.items == preview.items)
    #expect(terminated.withLock { $0.sorted() } == [5001, 5005, 5006])
    let byKind = Dictionary(grouping: report.items, by: \.kind)
    #expect(byKind[.orphanProcess]?.compactMap(\.vm).sorted() == ["fresh", "gone", "idle"])
    #expect(byKind[.orphanDirectory]?.map(\.vm) == ["gone"])
    #expect(!FileManager.default.fileExists(atPath: segments.directory(of: "gone").path))
    for name in ["idle", "member", "live", "other", "quiet", "fresh"] {
      #expect(FileManager.default.fileExists(atPath: segments.directory(of: name).path), "\(name)")
    }
  }

  /// The lock files of an id with neither record nor directory go; young ones, those of a record
  /// or a directory, and the store, segment and start-gate locks stay.
  @Test func removesStaleLocks() async throws {
    let f = try Fixture()
    let record = try await f.create()
    let locks = f.store.locksDirectory
    let stale = ["vm-gone22.lock", "vm-gone22.op.lock", "vm-gone22.qmp-events.lock"]
    let kept = [
      "\(record.id).lock", "\(record.id).op.lock", "vm-dir222.lock", "store.lock",
      "segments.lock", "segment-lan.lock", "switch-lan.lock", "starts/admit.lock",
      "starts/slot-0.lock",
    ]
    for name in stale + kept {
      try Self.write(locks.appending(path: name), bytes: 0, modified: Self.old)
    }
    try Self.write(locks.appending(path: "vm-young2.lock"), bytes: 0)
    try FileManager.default.createDirectory(
      at: f.store.directory(of: "vm-dir222"), withIntermediateDirectories: true)

    var collector = GarbageCollector(manager: f.manager)
    collector.processes = Processes().inspector
    let report = await collector.run()
    #expect(report.errors.isEmpty, "\(report.errors)")
    let removed = report.items.filter { $0.kind == .staleLock }
    #expect(removed.map(\.target) == stale.sorted().map { locks.appending(path: $0).path })
    #expect(Set(removed.compactMap(\.vm)) == ["vm-gone22"])
    for name in stale {
      #expect(!FileManager.default.fileExists(atPath: locks.appending(path: name).path))
    }
    for name in kept + ["vm-young2.lock"] {
      #expect(FileManager.default.fileExists(atPath: locks.appending(path: name).path), "\(name)")
    }
  }

  /// A test home older than the limit has its confirmed engine and switch ended and goes; a young
  /// home, and one whose engine pid runs elsewhere, stay. A pid reused by another program is
  /// ignored.
  @Test func sweepsStaleTestHomes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "vmlab-sweep-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    func home(_ name: String, engine: Int32?, vz: Int32? = nil, switch: Int32? = nil) throws -> URL
    {
      let home = root.appending(path: name)
      let vm = home.appending(path: "vms/vm-aaaaaa")
      try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
      for (file, pid) in [("qemu.pid", engine), ("vz.pid", vz)] {
        if let pid {
          try "\(pid)\n".write(to: vm.appending(path: file), atomically: true, encoding: .utf8)
        }
      }
      if let pid = `switch` {
        let segment = home.appending(path: "segments/lan")
        try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
        try "\(pid)\n".write(
          to: segment.appending(path: "switch.pid"), atomically: true, encoding: .utf8)
      }
      return home
    }
    let stale = try home("vmlab-test-1-h1", engine: 6001, switch: 6002)
    let young = try home("vmlab-test-2-h1", engine: 6001)
    let foreign = try home("vmlab-test-3-h1", engine: 6003)
    let reused = try home("vmlab-test-4-h1", engine: nil, vz: 6004)
    let unreadable = try home("vmlab-test-5-h1", engine: 6005)
    let mac = try home("vmlab-test-6-h1", engine: nil, vz: 6006)
    let clone = root.appending(path: "tart/vm-macmac")
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    var record = VMRecord(
      id: "vm-macmac", name: "mac", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      features: [], image: "macos-base")
    record.tartClone = clone.path
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(
      at: mac.appending(path: "vms/vm-macmac"), withIntermediateDirectories: true)
    try encoder.encode(record).write(to: mac.appending(path: "vms/vm-macmac/vm.json"))
    let unrelated = try home("other-1", engine: 6001)
    let dayAgo = Date().addingTimeInterval(-25 * 3600)
    for directory in [stale, foreign, reused, unrelated, unreadable, mac] {
      try Self.age(directory, to: dayAgo)
    }

    let terminated = Mutex<[Int32]>([])
    let processes = ProcessInspector(
      isAlive: { (6001...6006).contains($0) },
      executablePath: {
        switch $0 {
        case 6001, 6003: "/opt/homebrew/bin/qemu-system-aarch64"
        case 6002: "/Users/x/vmlab/.build/debug/vmlab-switch"
        case 6004: "/bin/sleep"
        case 6006: "/usr/local/bin/vmlab-vz"
        default: nil
        }
      },
      terminate: { pid in terminated.withLock { $0.append(pid) } },
      runsVM: { pid, directory in
        switch pid {
        case 6001: directory == stale.appending(path: "vms/vm-aaaaaa")
        case 6002: directory == stale.appending(path: "segments/lan")
        case 6006: directory == mac.appending(path: "vms/vm-aaaaaa")
        default: false
        }
      })

    let lines = await GarbageCollector.sweepTestHomes(
      roots: [root], olderThan: .seconds(24 * 3600), processes: processes)
    #expect(terminated.withLock { $0 } == [6001, 6002, 6006])
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(!FileManager.default.fileExists(atPath: reused.path))
    for kept in [young, foreign, unrelated, unreadable, mac] {
      #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent)")
    }
    #expect(lines.count == 5, "\(lines)")
    #expect(lines.contains { $0.hasPrefix("left \(unreadable.path)") && $0.contains("6005") })
    #expect(lines.contains { $0.hasPrefix("left \(mac.path)") && $0.contains("Tart clone") })
    #expect(lines.contains { $0.hasPrefix("removed \(stale.path)") && $0.contains("pid 6002") })
    #expect(lines.contains { $0.hasPrefix("left \(foreign.path)") && $0.contains("6003") })
  }
}
