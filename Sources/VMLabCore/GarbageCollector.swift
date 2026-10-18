import Darwin
import Foundation

/// What `vmlab gc` removed (R-805).
public struct GCReport: Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    /// An engine process whose VM record is gone, and that VM's leftover directory.
    case orphanProcess = "orphan_process"
    case orphanDirectory = "orphan_directory"
    case dump
    case execLog = "exec_log"
    case temporaryCheckpoint = "temporary_checkpoint"
    /// A frozen layer under `<vm>/backing/` that no VM's backing chain reads any more.
    case backingFile = "backing_file"
    /// A template (R-804) under `images/` that no VM was created from or reads through.
    case templateImage = "template_image"
  }

  public struct Item: Codable, Sendable, Hashable {
    public var kind: Kind
    /// The file or directory removed, or `<vm>:<checkpoint>` for a checkpoint, `pid <n>` for a
    /// process.
    public var target: String
    public var bytes: UInt64
    public var vm: String?

    public init(kind: Kind, target: String, bytes: UInt64 = 0, vm: String? = nil) {
      self.kind = kind
      self.target = target
      self.bytes = bytes
      self.vm = vm
    }
  }

  public var items: [Item] = []
  /// What could not be removed, one line each; the rest went on.
  public var errors: [String] = []
  public var dryRun = false

  public var bytesFreed: UInt64 { items.reduce(0) { $0 + $1.bytes } }

  public init(dryRun: Bool = false) { self.dryRun = dryRun }
}

/// How the collector sees and ends host processes; injectable so tests touch none.
public struct ProcessInspector: Sendable {
  public var isAlive: @Sendable (Int32) -> Bool
  /// The executable's path (`proc_pidpath`), nil when unknown.
  public var executablePath: @Sendable (Int32) -> String?
  /// SIGTERM, a short wait, then SIGKILL.
  public var terminate: @Sendable (Int32) async -> Void

  public init(
    isAlive: @escaping @Sendable (Int32) -> Bool,
    executablePath: @escaping @Sendable (Int32) -> String?,
    terminate: @escaping @Sendable (Int32) async -> Void
  ) {
    self.isAlive = isAlive
    self.executablePath = executablePath
    self.terminate = terminate
  }

  public static let system = ProcessInspector(
    isAlive: LivenessProbe.processExists,
    executablePath: { pid in
      var buffer = [CChar](repeating: 0, count: 4096)
      let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
      guard length > 0 else { return nil }
      return String(
        decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    },
    terminate: { pid in
      kill(pid, SIGTERM)
      for _ in 0..<20 where LivenessProbe.processExists(pid) {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if LivenessProbe.processExists(pid) { kill(pid, SIGKILL) }
    })
}

/// `vmlab gc` (R-805): removes orphaned engine processes (pid files in a VM directory whose
/// `vm.json` is gone) with that directory, dumps and exec logs older than `maxAge`, temporary
/// checkpoints (the saves of `checkpoint_stop` that were resumed), and frozen layers in
/// `<vm>/backing/` that no VM's `backingChain` reads. Files younger than `grace` are left alone,
/// so a create or clone in flight in another process is never collected. A template (R-804) is
/// the backing file of its QEMU children: its `images/<name>/` goes when no VM names it as its
/// image (the rule `images prune` uses) and no backing chain reads a file in it, and it has not
/// changed for `maxAge`, so a template made for children not yet created survives a week. Pulled
/// images are left to `images prune`, and a home whose `images` is a link to another's cache
/// (the test homes) collects none.
public struct GarbageCollector: Sendable {
  public static let pidFiles = ["qemu.pid", "vz.pid"]
  /// The executables an engine pid file may name: QEMU's system emulators and the VZ runner.
  public static func isEngine(_ path: String) -> Bool {
    let name = URL(filePath: path).lastPathComponent
    return name.hasPrefix("qemu-system-") || name == "vmlab-vz"
  }

  public let manager: VMManager
  public var maxAge: Duration = .seconds(7 * 24 * 3600)
  public var grace: Duration = .seconds(600)
  public var now: @Sendable () -> Date = { Date() }
  public var processes: ProcessInspector = .system
  public var dryRun = false

  public init(manager: VMManager) { self.manager = manager }

  var store: Store { manager.store }

  public func run() async -> GCReport {
    var report = GCReport(dryRun: dryRun)
    let records: [VMRecord]
    do {
      records = try store.list().records
    } catch {
      report.errors.append("list VMs: \(error.message)")
      return report
    }
    await collectOrphans(into: &report)
    for record in records { collectOldFiles(of: record, into: &report) }
    for record in records { await collectTemporaryCheckpoints(of: record, into: &report) }
    collectBackingFiles(records: records, into: &report)
    collectTemplates(records: records, into: &report)
    return report
  }

  // MARK: Steps

  func collectOrphans(into report: inout GCReport) async {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: store.vmsDirectory.path)) ?? []
    for name in names.sorted() where !name.hasPrefix(".") {
      let directory = store.vmsDirectory.appending(path: name)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        !FileManager.default.fileExists(
          atPath: directory.appending(path: Store.recordFileName).path),
        isOld(directory, than: grace)
      else { continue }
      for file in Self.pidFiles {
        guard let text = try? String(contentsOf: directory.appending(path: file), encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
          processes.isAlive(pid), let path = processes.executablePath(pid), Self.isEngine(path)
        else { continue }
        if !dryRun { await processes.terminate(pid) }
        report.items.append(
          GCReport.Item(kind: .orphanProcess, target: "pid \(pid) (\(path))", vm: name))
      }
      remove(directory, kind: .orphanDirectory, vm: name, into: &report)
      if !dryRun {
        try? FileManager.default.removeItem(
          at: store.locksDirectory.appending(path: "\(name).lock"))
      }
    }
  }

  func collectOldFiles(of record: VMRecord, into report: inout GCReport) {
    let directory = store.directory(of: record.id)
    for (sub, kind, suffix) in [("dumps", GCReport.Kind.dump, nil), ("exec", .execLog, ".log")] {
      let folder = directory.appending(path: sub)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
      for name in names.sorted() where suffix.map(name.hasSuffix) ?? true {
        let file = folder.appending(path: name)
        guard isOld(file, than: maxAge) else { continue }
        remove(file, kind: kind, vm: record.id, into: &report)
      }
    }
  }

  func collectTemporaryCheckpoints(of record: VMRecord, into report: inout GCReport) async {
    guard let tree = try? store.checkpoints(of: record.id) else { return }
    for node in tree.nodes where node.temporary && node.id != tree.resume {
      let target = "\(record.id):\(node.name)"
      if dryRun {
        report.items.append(
          GCReport.Item(kind: .temporaryCheckpoint, target: target, vm: record.id))
        continue
      }
      do {
        try await manager.dropCheckpoint(record.id, id: node.id)
        report.items.append(
          GCReport.Item(kind: .temporaryCheckpoint, target: target, vm: record.id))
      } catch {
        report.errors.append("checkpoint \(target): \(error.message)")
      }
    }
  }

  func collectBackingFiles(records: [VMRecord], into report: inout GCReport) {
    let used = Set(
      records.flatMap { $0.backingChain ?? [] }.map { URL(filePath: $0).standardizedFileURL.path })
    for record in records {
      let folder = store.directory(of: record.id).appending(path: "backing")
      let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
      for name in names.sorted() {
        let file = folder.appending(path: name)
        guard !used.contains(file.standardizedFileURL.path), isOld(file, than: grace) else {
          continue
        }
        remove(file, kind: .backingFile, vm: record.id, into: &report)
      }
    }
  }

  func collectTemplates(records: [VMRecord], into report: inout GCReport) {
    let images = ImageStore(home: store.home)
    let linked =
      (try? images.directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
      ?? false
    guard !linked else { return }
    let named = ImageStore.references(records)
    let chains = records.flatMap { $0.backingChain ?? [] }.map {
      URL(filePath: $0).standardizedFileURL.path
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: images.directory.path)) ?? []
    for name in names.sorted() where !name.hasPrefix(".") && !named.contains(name) {
      guard images.pulled(name)?.template != nil else { continue }
      let directory = images.imageDirectory(name)
      let prefix = directory.standardizedFileURL.path + "/"
      guard !chains.contains(where: { $0.hasPrefix(prefix) }),
        isOld(directory.appending(path: "image.json"), than: maxAge)
      else { continue }
      remove(directory, kind: .templateImage, vm: nil, into: &report)
    }
  }

  // MARK: Helpers

  func isOld(_ url: URL, than age: Duration) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let modified = attributes[.modificationDate] as? Date
    else { return false }
    return now().timeIntervalSince(modified) > Double(age.components.seconds)
  }

  func remove(_ url: URL, kind: GCReport.Kind, vm: String?, into report: inout GCReport) {
    let bytes = Self.allocatedBytes(url)
    if !dryRun {
      do { try FileManager.default.removeItem(at: url) } catch {
        report.errors.append("remove \(url.path): \(error.localizedDescription)")
        return
      }
    }
    report.items.append(GCReport.Item(kind: kind, target: url.path, bytes: bytes, vm: vm))
  }

  /// The bytes a file or directory tree occupies on disk.
  static func allocatedBytes(_ url: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
    guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
    guard values.isDirectory == true else { return UInt64(values.totalFileAllocatedSize ?? 0) }
    var total: UInt64 = 0
    let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
    while let file = walker?.nextObject() as? URL {
      total += UInt64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
    }
    return total
  }
}

extension VMManager {
  /// Deletes the single checkpoint `id` of `vm` (its engine snapshot and its node); its children
  /// move up to its parent. `vmlab gc` uses it for temporary checkpoints.
  public func dropCheckpoint(_ vm: String, id checkpoint: String) async throws(VMLabError) {
    let id = try store.find(vm).id
    await acquire(id)
    defer { release(id) }
    let record = try store.load(id: id)
    let tree = try store.checkpoints(of: id)
    guard let node = tree.node(id: checkpoint), node.id != tree.resume else { return }
    let provider = try await backends.backend(for: record.profile).checkpoints(record)
    do {
      try await provider.delete(id: node.id)
    } catch  where error.code == .invalidRequest && error.data["field"] == .string("id") {
      // Already gone from the engine.
    }
    try store.updateCheckpoints(of: id) { (tree: inout CheckpointTree, _) throws(VMLabError) in
      Self.remove(node.id, from: &tree)
    }
    await log(id, "checkpoint deleted by gc: \(node.name) (\(node.id))", kind: .checkpoint)
  }
}
