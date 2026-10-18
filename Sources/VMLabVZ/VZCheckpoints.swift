import Darwin
import Foundation
import VMLabCore

/// Checkpoints of a `vz-linux` guest (R-608), each in `<vm>/checkpoints/<id>/` (Appendix F):
/// APFS clones (`clonefile(2)`) of the disk and the auxiliary storage beside it (`disk.raw`,
/// `efi-vars.bin`, `machine-id.bin`; for `vz-macos` the Tart clone's `disk.img` and `nvram.bin`),
/// the VM's first-boot record (`provisioningFiles`, CX-26), plus for a live checkpoint the
/// runner's `saveMachineStateTo` file and the `vz-config.json` the saved machine was built from.
///
/// `disk` mode works on a guest that is not running: create clones the files out, restore clones
/// them back. `live` mode needs a running or paused guest: create pauses it, saves its state,
/// clones the files and resumes it if it was running; restore ends the runner, clones the files
/// back, starts a held runner from the checkpoint's configuration and has it
/// `restoreMachineStateFrom` the saved state (Virtualization.framework restores only into a
/// machine that has never started), then resumes it unless the VM was paused. The new runner's
/// endpoints are written to `vm.json`.
public struct VZCheckpoints: CheckpointProvider {
  public static let directoryName = "checkpoints"
  public static let stateFile = "state.vzvmsave"
  public static let configFile = "vz-config.json"
  /// The VM files a checkpoint clones: the disk and the auxiliary storage beside it.
  public static let clonedFiles = ["disk.raw", "efi-vars.bin", "machine-id.bin"]
  /// CX-26: the host-side record of the guest's first boot, which must match the disk: R-606's
  /// `provisioned` marker (a restored disk without the VM's key must be provisioned again) and
  /// the `provision.json` report with its log. Kept in the checkpoint beside the disk, restored
  /// with it, and removed by a restore of a checkpoint taken before they existed.
  public static let provisioningFiles = ["provisioned", "provision.json", "provision.log"]
  /// Names the `provisioningFiles` a checkpoint holds; a checkpoint without it (made before
  /// CX-26) leaves the VM's provisioning files as they are.
  static let provisioningManifest = "provisioning.json"
  /// Written by a start of a `suspended` VM, which leaves a held runner built from this
  /// checkpoint; the restore that follows only has to load the state into it.
  static let heldMarker = "vz-held-for"

  public let backend: VZBackend
  public let record: VMRecord

  public init(backend: VZBackend, record: VMRecord) {
    self.backend = backend
    self.record = record
  }

  var vmDirectory: URL { backend.store.directory(of: record.id) }
  var files: [(live: URL, name: String)] {
    Self.stateFiles(of: record, vmDirectory: vmDirectory)
  }
  var provisioning: [(live: URL, name: String)] { Self.provisioningFiles(vmDirectory: vmDirectory) }

  public static func directory(of id: String, vmDirectory: URL) -> URL {
    vmDirectory.appending(path: "\(directoryName)/\(id)", directoryHint: .isDirectory)
  }

  // MARK: CheckpointProvider

  public func create(id: String, mode: CheckpointMode) async throws(VMLabError) {
    let folder = Self.directory(of: id, vmDirectory: vmDirectory)
    guard !FileManager.default.fileExists(atPath: folder.path) else {
      throw VMLabError.invalidRequest(
        field: "id", reason: "checkpoint \(id) already exists",
        hint: "Use a new checkpoint id.")
    }
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      throw Self.ioError("create \(folder.path)", error)
    }
    do {
      switch mode {
      case .disk:
        try await refuseIfRunning("take a disk checkpoint")
        try Self.save(files, provisioning: provisioning, into: folder)
      case .live:
        try await saveLive(into: folder)
      }
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }

  public func restore(id: String, mode: CheckpointMode) async throws(VMLabError) {
    let folder = try existing(id)
    switch mode {
    case .disk:
      try await refuseIfRunning("restore a disk checkpoint")
      try Self.load(files, provisioning: provisioning, from: folder)
    case .live:
      try await restoreLive(id: id, from: folder)
    }
  }

  public func delete(id: String) async throws(VMLabError) {
    let folder = try existing(id)
    do { try FileManager.default.removeItem(at: folder) } catch {
      throw Self.ioError("remove \(folder.path)", error)
    }
  }

  // MARK: Live

  private func saveLive(into folder: URL) async throws(VMLabError) {
    let (client, _) = backend.target(record)
    let state = try await client.status().state
    guard state == .running || state == .paused else {
      throw Self.notLive(record, state: state?.rawValue ?? "unknown")
    }
    if state == .running { try await client.pause() }
    do {
      try await client.save(to: folder.appending(path: Self.stateFile).path)
      try Self.save(files, provisioning: provisioning, into: folder)
      try Self.clone(
        VZRunnerPaths(vmDirectory: vmDirectory).config,
        to: folder.appending(path: Self.configFile))
    } catch {
      if state == .running { _ = try? await client.resume() }
      throw error
    }
    if state == .running { try await client.resume() }
  }

  private func restoreLive(id: String, from folder: URL) async throws(VMLabError) {
    guard record.state.isLive || record.state == .suspended else {
      throw Self.notLive(record, state: record.state.rawValue)
    }
    let saved = folder.appending(path: Self.stateFile)
    guard FileManager.default.fileExists(atPath: saved.path) else {
      throw VMLabError.invalidRequest(
        field: "id", reason: "checkpoint \(id) has no saved machine state",
        hint: "Restore it as a disk checkpoint of the stopped VM.")
    }
    let paths = VZRunnerPaths(vmDirectory: vmDirectory)
    let (client, _) = backend.target(record)
    let held =
      (try? String(contentsOf: vmDirectory.appending(path: Self.heldMarker), encoding: .utf8))
    let state = try? await client.status().state
    var runtime = record.runtime
    if held != id || state != .stopped {
      // A running guest cannot load a saved state: end it and build a held machine from the
      // checkpoint's files and configuration.
      try await backend.kill(record)
      runtime = try await backend.prepareHeld(record, checkpoint: id)
    }
    try? FileManager.default.removeItem(at: vmDirectory.appending(path: Self.heldMarker))
    let fresh = VZControlClient(socketPath: runtime?.controlSocket ?? paths.controlSocket.path)
    do {
      try await fresh.restore(from: saved.path)
      if record.state != .paused { try await fresh.resume() }
    } catch {
      _ = try? await fresh.exit()
      throw error
    }
    await backend.reconnectSerial(record)
    if let runtime, runtime != record.runtime, record.state != .suspended {
      // The manager keeps the record's runtime; the runner changed under it.
      _ = try? backend.store.update(id: record.id) { $0.runtime = runtime }
    }
  }

  // MARK: Helpers

  private func existing(_ id: String) throws(VMLabError) -> URL {
    let folder = Self.directory(of: id, vmDirectory: vmDirectory)
    guard FileManager.default.fileExists(atPath: folder.path) else {
      throw VMLabError.invalidRequest(
        field: "id", reason: "no engine checkpoint \(id) in \(vmDirectory.lastPathComponent)",
        hint: "List the VM's checkpoints with vm_checkpoint list.")
    }
    return folder
  }

  private func refuseIfRunning(_ what: String) async throws(VMLabError) {
    let (client, pid) = backend.target(record)
    var answering = false
    if pid > 0, LivenessProbe.processExists(pid) {
      answering = (try? await client.status()) != nil
    }
    guard record.state.isLive || answering else { return }
    throw VMLabError(
      code: .wrongState,
      message: "VM \(record.id) is \(record.state.rawValue); cannot \(what) while it runs",
      hint: "Stop it first (vm_lifecycle stop), or use a live checkpoint.",
      data: [
        "vm": .string(record.id), "state": .string(record.state.rawValue),
        "legalActions": .array(
          Lifecycle.legalActions(in: record.state).map { .string($0.rawValue) }),
      ])
  }

  static func notLive(_ record: VMRecord, state: String) -> VMLabError {
    VMLabError(
      code: .wrongState,
      message: "VM \(record.id) is \(state); a live checkpoint needs it running or paused",
      hint: "Start it first (vm_lifecycle start), or use a disk checkpoint.",
      data: [
        "vm": .string(record.id), "state": .string(record.state.rawValue),
        "legalActions": .array(
          Lifecycle.legalActions(in: record.state).map { .string($0.rawValue) }),
      ])
  }

  /// The files a checkpoint of `record` clones: each live file and its name in the checkpoint.
  /// A `vz-linux` guest's are `clonedFiles` in its VM directory; a `vz-macos` guest's are its
  /// Tart clone's `disk.img` and `nvram.bin` (the auxiliary storage).
  static func stateFiles(of record: VMRecord, vmDirectory: URL) -> [(live: URL, name: String)] {
    if record.profile == .vzMacOS, let path = record.tartClone {
      let clone = TartVMFiles(directory: URL(filePath: path))
      return [(clone.disk, "disk.img"), (clone.nvram, "nvram.bin")]
    }
    return clonedFiles.map { (vmDirectory.appending(path: $0), $0) }
  }

  /// The VM directory's `provisioningFiles`, each with its name in a checkpoint.
  static func provisioningFiles(vmDirectory: URL) -> [(live: URL, name: String)] {
    provisioningFiles.map { (vmDirectory.appending(path: $0), $0) }
  }

  /// Clones the record's live files and its `provisioning` files that exist into checkpoint
  /// `folder`, with the manifest naming the provisioning files it holds.
  static func save(
    _ files: [(live: URL, name: String)], provisioning: [(live: URL, name: String)] = [],
    into folder: URL, using ops: FileOps = .system
  ) throws(VMLabError) {
    let present = provisioning.filter { FileManager.default.fileExists(atPath: $0.live.path) }
    if !provisioning.isEmpty {
      let manifest = folder.appending(path: provisioningManifest)
      do {
        try JSONEncoder().encode(present.map(\.name)).write(to: manifest, options: .atomic)
      } catch {
        throw ioError("write \(manifest.path)", error)
      }
    }
    try replace(
      (files.filter { FileManager.default.fileExists(atPath: $0.live.path) } + present).map {
        ($0.live, folder.appending(path: $0.name))
      }, using: ops)
  }

  /// Clones checkpoint `folder`'s files back over the record's live files, all or none. A
  /// `provisioning` file the checkpoint's manifest does not name is removed in the same swap, so
  /// the VM's first-boot record always matches the disk it has.
  static func load(
    _ files: [(live: URL, name: String)], provisioning: [(live: URL, name: String)] = [],
    from folder: URL, using ops: FileOps = .system
  ) throws(VMLabError) {
    var pairs: [(from: URL?, to: URL)] = files.map { (folder.appending(path: $0.name), $0.live) }
      .filter { FileManager.default.fileExists(atPath: $0.0.path) }
    if let data = try? Data(contentsOf: folder.appending(path: provisioningManifest)),
      let held = try? JSONDecoder().decode([String].self, from: data)
    {
      for file in provisioning {
        let saved = folder.appending(path: file.name)
        if held.contains(file.name), FileManager.default.fileExists(atPath: saved.path) {
          pairs.append((saved, file.live))
        } else if FileManager.default.fileExists(atPath: file.live.path) {
          pairs.append((nil, file.live))
        }
      }
    }
    try replace(pairs, using: ops)
  }

  /// Clones one file over another (or into place).
  static func clone(_ from: URL, to: URL, using ops: FileOps = .system) throws(VMLabError) {
    try replace([(from, to)], using: ops)
  }

  /// The file operations a checkpoint's copies use; tests inject failures.
  struct FileOps: Sendable {
    /// Copies a file to a path that does not exist.
    var copy: @Sendable (URL, URL) throws -> Void
    /// Atomically swaps two existing files, or renames the first to the second when the
    /// second does not exist.
    var exchange: @Sendable (URL, URL) throws -> Void

    static let system = FileOps(
      copy: { from, to in
        // `clonefile(2)` (an instant APFS copy-on-write clone), else a plain copy.
        if clonefile(from.path, to.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: from, to: to)
      },
      exchange: { a, b in
        if !FileManager.default.fileExists(atPath: b.path) {
          guard rename(a.path, b.path) == 0 else { throw posixError() }
          return
        }
        if renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 { return }
        guard errno == ENOTSUP || errno == EINVAL else { throw posixError() }
        // A volume without RENAME_SWAP: three renames through a spare name.
        let spare = b.deletingLastPathComponent().appending(
          path: ".\(b.lastPathComponent).vmlab-swap-\(UUID().uuidString)")
        guard rename(b.path, spare.path) == 0 else { throw posixError() }
        guard rename(a.path, b.path) == 0 else {
          let error = posixError()
          _ = rename(spare.path, b.path)
          throw error
        }
        guard rename(spare.path, a.path) == 0 else { throw posixError() }
      })

    static func posixError() -> POSIXError {
      POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Replaces each pair's destination with a copy of its source (or removes it when the source
  /// is nil), all or none. Every source is first copied to a temporary beside its destination;
  /// only when all copies exist is each swapped into place (`renamex_np(RENAME_SWAP)`, atomic per
  /// file, so a destination is never missing); a removal renames the destination to its
  /// temporary. A failed swap swaps the earlier ones back. The previous files, left in the
  /// temporaries by the swaps, are removed at the end.
  static func replace(_ pairs: [(from: URL?, to: URL)], using ops: FileOps) throws(VMLabError) {
    let temps = pairs.map { pair in
      pair.to.deletingLastPathComponent().appending(
        path: ".\(pair.to.lastPathComponent).vmlab-new-\(UUID().uuidString)")
    }
    defer { for temp in temps { try? FileManager.default.removeItem(at: temp) } }
    for (pair, temp) in zip(pairs, temps) {
      guard let from = pair.from else { continue }
      do { try ops.copy(from, temp) } catch {
        throw ioError("clone \(from.path) to \(pair.to.path)", error)
      }
    }
    // Whether each destination existed: a swap of a new file is a rename, undone by renaming
    // back; a removal is a rename of the destination to the temporary, undone the same way.
    var swapped: [(temp: URL, to: URL, existed: Bool, removal: Bool)] = []
    for (pair, temp) in zip(pairs, temps) {
      let existed = FileManager.default.fileExists(atPath: pair.to.path)
      let removal = pair.from == nil
      if removal && !existed { continue }
      do {
        if removal { try ops.exchange(pair.to, temp) } else { try ops.exchange(temp, pair.to) }
      } catch {
        for done in swapped.reversed() {
          if done.removal {
            _ = rename(done.temp.path, done.to.path)
          } else if done.existed {
            try? ops.exchange(done.temp, done.to)
          } else {
            _ = rename(done.to.path, done.temp.path)
          }
        }
        throw ioError("replace \(pair.to.path)", error)
      }
      swapped.append((temp, pair.to, existed, removal))
    }
  }

  static func ioError(_ what: String, _ error: any Error) -> VMLabError {
    VMLabError(
      code: .internal, message: "Cannot \(what): \(error)",
      hint: "Check free disk space and permissions under VMLAB_HOME.")
  }
}

extension VZBackend {
  /// Checkpoints of the VM in any state (R-608).
  public func checkpoints(_ record: VMRecord) async throws(VMLabError) -> any CheckpointProvider {
    VZCheckpoints(backend: self, record: record)
  }

  /// Clones checkpoint `id`'s files into the VM directory and starts a held runner (`--hold`)
  /// from the checkpoint's saved configuration, ready for `restore`. Returns its endpoints.
  func prepareHeld(_ record: VMRecord, checkpoint id: String) async throws(VMLabError)
    -> VMRuntime
  {
    let dir = store.directory(of: record.id)
    let folder = VZCheckpoints.directory(of: id, vmDirectory: dir)
    try VZCheckpoints.load(
      VZCheckpoints.stateFiles(of: record, vmDirectory: dir),
      provisioning: VZCheckpoints.provisioningFiles(vmDirectory: dir), from: folder)
    let config = try VZRunnerConfig.read(from: folder.appending(path: VZCheckpoints.configFile))
    await serialChannels.drop(record.id)
    let handle = try await launcher.launch(vmDirectory: dir, config: config, hold: true)
    var runtime = handle.runtime
    runtime.serialSocket = config.serialSocket
    if case .nat(let mac?) = config.network.first {
      runtime.ip = DHCPLeases.lookup(mac: mac, path: leasePath) ?? record.runtime?.ip
    }
    return runtime
  }

  /// A suspended VM's start (R-800's `checkpoint_stop`): a held runner built from the checkpoint
  /// it resumes from; the manager's restore then loads the saved state into it.
  func startSuspended(_ record: VMRecord) async throws(VMLabError) -> VMRuntime? {
    guard record.state == .suspended, let resume = try store.checkpoints(of: record.id).resume
    else { return nil }
    let runtime = try await prepareHeld(record, checkpoint: resume)
    let marker = store.directory(of: record.id).appending(path: VZCheckpoints.heldMarker)
    try? resume.write(to: marker, atomically: true, encoding: .utf8)
    return runtime
  }

  /// Reconnects the serial channel of a guest whose runner was replaced.
  func reconnectSerial(_ record: VMRecord) async {
    await serialChannels.drop(record.id)
    guard record.features.contains(.serial) else { return }
    let dir = store.directory(of: record.id)
    _ = try? await serialChannels.channel(
      for: record.id, socket: VZRunnerPaths(vmDirectory: dir).serialSocket.path, vmDirectory: dir)
  }
}
