import Foundation

// MARK: - Tree

/// One checkpoint of a VM (R-800): a node of the tree in `<vm>/checkpoints.json`. `id` names the
/// engine snapshot (`CheckpointProvider`); `name` is the model's, unique per VM.
public struct CheckpointNode: Codable, Sendable, Hashable {
  public var id: String
  public var name: String
  /// The node that was current when this one was taken; nil for a root.
  public var parent: String?
  public var mode: CheckpointMode
  public var createdAt: Date
  /// The VM's state when the checkpoint was taken.
  public var state: VMState
  /// The guest manifest taken with it (R-801), when one exists.
  public var manifestPath: String?
  public var note: String?
  /// Made by vmlab itself (the save of a `checkpoint_stop`); `vmlab gc` removes it (R-805).
  public var temporary: Bool

  public init(
    id: String, name: String, parent: String? = nil, mode: CheckpointMode,
    createdAt: Date = Date(), state: VMState, manifestPath: String? = nil, note: String? = nil,
    temporary: Bool = false
  ) {
    self.id = id
    self.name = name
    self.parent = parent
    self.mode = mode
    self.createdAt = createdAt
    self.state = state
    self.manifestPath = manifestPath
    self.note = note
    self.temporary = temporary
  }

  enum CodingKeys: String, CodingKey {
    case id, name, parent, mode, createdAt, state, manifestPath, note, temporary
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    parent = try c.decodeIfPresent(String.self, forKey: .parent)
    mode = try c.decode(CheckpointMode.self, forKey: .mode)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    state = try c.decode(VMState.self, forKey: .state)
    manifestPath = try c.decodeIfPresent(String.self, forKey: .manifestPath)
    note = try c.decodeIfPresent(String.self, forKey: .note)
    temporary = try c.decodeIfPresent(Bool.self, forKey: .temporary) ?? false
  }

  /// The node as `vm_checkpoint` returns it.
  public var json: JSONValue {
    var object: [String: JSONValue] = [
      "id": .string(id), "name": .string(name), "mode": .string(mode.rawValue),
      "createdAt": .string(createdAt.formatted(.iso8601)), "state": .string(state.rawValue),
    ]
    if let parent { object["parent"] = .string(parent) }
    if let manifestPath { object["manifestPath"] = .string(manifestPath) }
    if let note { object["note"] = .string(note) }
    if temporary { object["temporary"] = .bool(true) }
    return .object(object)
  }
}

/// The contents of `<vm>/checkpoints.json`: every node in creation order, the current node (the
/// one the guest descends from) and, while the VM is `suspended`, the live checkpoint its next
/// start resumes from.
public struct CheckpointTree: Codable, Sendable, Hashable {
  public static let fileName = "checkpoints.json"
  public static let currentSchemaVersion = 1
  /// The name that resolves to the newest checkpoint.
  public static let latest = "@latest"

  public var schemaVersion: Int
  public var current: String?
  public var resume: String?
  public var nodes: [CheckpointNode]

  public init(current: String? = nil, resume: String? = nil, nodes: [CheckpointNode] = []) {
    self.schemaVersion = Self.currentSchemaVersion
    self.current = current
    self.resume = resume
    self.nodes = nodes
  }

  public func node(id: String) -> CheckpointNode? { nodes.first { $0.id == id } }

  /// The node named `name`, or the newest for `@latest`; `invalid_request` (field `name`) when
  /// there is none.
  public func resolve(_ name: String) throws(VMLabError) -> CheckpointNode {
    let found =
      name == Self.latest
      ? nodes.last  // nodes are kept in creation order
      : nodes.first { $0.name == name }
    guard let found else {
      let names = nodes.map(\.name)
      throw VMLabError.invalidRequest(
        field: "name", reason: "no checkpoint named \(name)",
        hint: names.isEmpty
          ? "This VM has no checkpoints; create one first."
          : "Use one of: \(names.joined(separator: ", ")).")
    }
    return found
  }

  public func children(of id: String) -> [CheckpointNode] { nodes.filter { $0.parent == id } }

  /// Every descendant of `id`, deepest first, so deleting them in order never orphans a node.
  public func descendants(of id: String) -> [CheckpointNode] {
    children(of: id).flatMap { descendants(of: $0.id) + [$0] }
  }

  /// The record's summary of the tree.
  public var refs: [CheckpointRef] { nodes.map { CheckpointRef(id: $0.id, name: $0.name) } }

  /// The tree as `vm_checkpoint list` returns it.
  public var json: JSONValue {
    var object: [String: JSONValue] = ["nodes": .array(nodes.map(\.json))]
    if let current { object["current"] = .string(current) }
    if let resume { object["resume"] = .string(resume) }
    return .object(object)
  }

  /// `cp-` plus six base32 characters, not yet in the tree: a valid engine snapshot tag.
  func newID() -> String {
    var id: String
    repeat {
      id = "cp-" + StoreIDs.random().dropFirst(3)
    } while node(id: id) != nil
    return id
  }
}

/// Takes a guest manifest (R-801) for a checkpoint and returns where it is stored.
public protocol GuestManifestTaker: Sendable {
  func take(_ record: VMRecord, checkpoint: String) async throws(VMLabError) -> String
}

/// What `vm_checkpoint create` asks for: `auto` takes `live` when the plan granted it and the
/// guest is running, else `disk`.
public enum CheckpointModeRequest: String, CaseIterable, Codable, Sendable {
  case auto, disk, live
}

// MARK: - Store

extension Store {
  public func checkpointsURL(of id: String) -> URL {
    directory(of: id).appending(path: CheckpointTree.fileName)
  }

  /// The VM's checkpoint tree; empty when it has none yet.
  public func checkpoints(of id: String) throws(VMLabError) -> CheckpointTree {
    let url = checkpointsURL(of: id)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      _ = try load(id: id)
      return CheckpointTree()
    } catch {
      throw Self.ioError("read \(url.path)", error)
    }
    do {
      return try Self.decoder.decode(CheckpointTree.self, from: data)
    } catch {
      throw Self.corrupt(url.path, "\(error)")
    }
  }

  /// Read-modify-write of the VM's checkpoint tree under its lock; `vm.json`'s `checkpoints`
  /// summary is rewritten with it.
  @discardableResult
  public func updateCheckpoints<T>(
    of id: String, _ body: (inout CheckpointTree, VMRecord) throws(VMLabError) -> T
  ) throws(VMLabError) -> T {
    try withLock(id) { () throws(VMLabError) -> T in
      var record = try load(id: id)
      var tree = try checkpoints(of: id)
      let result = try body(&tree, record)
      tree.schemaVersion = CheckpointTree.currentSchemaVersion
      let data: Data
      do { data = try Self.encoder.encode(tree) } catch {
        throw Self.ioError("encode \(CheckpointTree.fileName)", error)
      }
      try Self.writeAtomically(data, to: checkpointsURL(of: id))
      if record.checkpoints != tree.refs {
        record.checkpoints = tree.refs
        try writeRecord(record)
      }
      return result
    }
  }
}

// MARK: - Manager

/// The result of `VMManager.createCheckpoint`.
public struct CheckpointCreation: Sendable, Hashable {
  public var node: CheckpointNode
  public var warnings: [String]
}

extension VMManager {
  /// The VM's checkpoint tree.
  public func checkpoints(of vm: String) throws(VMLabError) -> CheckpointTree {
    try store.checkpoints(of: try store.find(vm).id)
  }

  /// Takes checkpoint `name` of `vm` as a child of the current node, which it becomes. `auto` is
  /// `live` when the plan granted `checkpoint_live` and the guest is running or paused, else
  /// `disk`; a running guest without `checkpoint_live` is `wrong_state` (stopping first is never
  /// implicit). `manifest` also takes a guest manifest when this build can (R-801), else the
  /// checkpoint is taken without one and a warning says so.
  public func createCheckpoint(
    _ vm: String, name: String, mode: CheckpointModeRequest = .auto, manifest: Bool = false,
    note: String? = nil, temporary: Bool = false
  ) async throws(VMLabError) -> CheckpointCreation {
    let id = try store.find(vm).id
    await acquire(id)
    defer { release(id) }
    return try await takeCheckpoint(
      id, name: name, mode: mode, manifest: manifest, note: note, temporary: temporary)
  }

  /// Returns the VM to checkpoint `name` (or `@latest`), which becomes the current node. A live
  /// checkpoint needs a running guest and leaves it running from the saved memory; a disk one
  /// rewinds a stopped guest's disk. The engine refuses a mode the state cannot serve.
  public func restoreCheckpoint(
    _ vm: String, name: String
  ) async throws(VMLabError) -> (node: CheckpointNode, record: VMRecord) {
    let id = try store.find(vm).id
    await acquire(id)
    defer { release(id) }
    let record = try store.load(id: id)
    try Self.checkCheckpointState(record, doing: "restore a checkpoint")
    let node = try store.checkpoints(of: id).resolve(name)
    let provider = try await backends.backend(for: record.profile).checkpoints(record)
    try await provider.restore(id: node.id, mode: node.mode)
    try store.updateCheckpoints(of: id) { (tree: inout CheckpointTree, _) throws(VMLabError) in
      tree.current = node.id
    }
    await log(
      id, "checkpoint restored: \(node.name) (\(node.id), \(node.mode.rawValue))", kind: .checkpoint
    )
    return (node, try store.load(id: id))
  }

  /// Deletes checkpoint `name`; one with children only when `recursive`, descendants first. When
  /// the current node goes, its nearest surviving ancestor becomes current. Returns the deleted
  /// nodes in deletion order.
  public func deleteCheckpoint(
    _ vm: String, name: String, recursive: Bool = false
  ) async throws(VMLabError) -> [CheckpointNode] {
    let id = try store.find(vm).id
    await acquire(id)
    defer { release(id) }
    let record = try store.load(id: id)
    let tree = try store.checkpoints(of: id)
    let node = try tree.resolve(name)
    let doomed = tree.descendants(of: node.id) + [node]
    if doomed.count > 1, !recursive {
      throw VMLabError.invalidRequest(
        field: "recursive",
        reason: "checkpoint \(node.name) has \(doomed.count - 1) descendant(s)",
        hint: "Delete with recursive: true to remove it and its descendants, or delete them first.")
    }
    if let resume = tree.resume, doomed.contains(where: { $0.id == resume }) {
      throw VMLabError(
        code: .wrongState,
        message: "VM \(id) is suspended and resumes from checkpoint \(resume)",
        hint: "Start the VM first (vm_lifecycle start); then the checkpoint can be deleted.",
        data: [
          "vm": .string(id), "state": .string(record.state.rawValue),
          "legalActions": .array(
            Lifecycle.legalActions(in: record.state).map { .string($0.rawValue) }),
        ])
    }
    let provider = try await backends.backend(for: record.profile).checkpoints(record)
    var deleted: [CheckpointNode] = []
    for victim in doomed {
      do {
        try await provider.delete(id: victim.id)
      } catch  where error.code == .invalidRequest && error.data["field"] == .string("id") {
        // The engine snapshot is already gone; drop the node all the same.
      }
      try store.updateCheckpoints(of: id) { (tree: inout CheckpointTree, _) throws(VMLabError) in
        Self.remove(victim.id, from: &tree)
      }
      deleted.append(victim)
      await log(id, "checkpoint deleted: \(victim.name) (\(victim.id))", kind: .checkpoint)
    }
    return deleted
  }

  /// Removes node `id` from `tree`; a current node passes to its nearest surviving ancestor.
  static func remove(_ id: String, from tree: inout CheckpointTree) {
    guard let node = tree.node(id: id) else { return }
    tree.nodes.removeAll { $0.id == id }
    for index in tree.nodes.indices where tree.nodes[index].parent == id {
      tree.nodes[index].parent = node.parent
    }
    if tree.current == id { tree.current = node.parent }
    if tree.resume == id { tree.resume = nil }
  }

  // MARK: Internals (the caller holds the VM)

  func takeCheckpoint(
    _ id: String, name: String, mode request: CheckpointModeRequest, manifest: Bool,
    note: String?, temporary: Bool
  ) async throws(VMLabError) -> CheckpointCreation {
    let record = try store.load(id: id)
    guard VMRecord.isValidName(name) else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "invalid checkpoint name \"\(name)\"",
        hint: "Use 1 to 64 letters, digits, '.', '_' or '-', starting with a letter or digit.")
    }
    if try store.checkpoints(of: id).nodes.contains(where: { $0.name == name }) {
      throw VMLabError.invalidRequest(
        field: "name", reason: "VM \(id) already has a checkpoint named \(name)",
        hint: "Choose another name, or delete the old checkpoint first.")
    }
    try Self.checkCheckpointState(record, doing: "take a checkpoint")
    let mode = try Self.resolveMode(request, for: record)
    let tree = try store.checkpoints(of: id)
    let checkpointID = tree.newID()
    let provider = try await backends.backend(for: record.profile).checkpoints(record)
    try await provider.create(id: checkpointID, mode: mode)

    var warnings: [String] = []
    var manifestPath: String?
    if manifest {
      if let manifests {
        do {
          manifestPath = try await manifests.take(record, checkpoint: checkpointID)
        } catch {
          warnings.append("the checkpoint was taken without a manifest: \(error.message)")
        }
      } else {
        warnings.append(
          "manifest: true was ignored: this manager takes no guest manifests; "
            + "the checkpoint has no manifest")
      }
    }
    let node = CheckpointNode(
      id: checkpointID, name: name, parent: tree.current, mode: mode, state: record.state,
      manifestPath: manifestPath, note: note, temporary: temporary)
    do {
      try store.updateCheckpoints(of: id) { (tree: inout CheckpointTree, _) throws(VMLabError) in
        guard !tree.nodes.contains(where: { $0.name == name }) else {
          throw VMLabError.invalidRequest(
            field: "name", reason: "VM \(id) already has a checkpoint named \(name)",
            hint: "Choose another name, or delete the old checkpoint first.")
        }
        var placed = node
        placed.parent = tree.current
        tree.nodes.append(placed)
        tree.current = placed.id
      }
    } catch {
      try? await provider.delete(id: checkpointID)
      throw error
    }
    await log(
      id, "checkpoint created: \(name) (\(checkpointID), \(mode.rawValue))", kind: .checkpoint)
    return CheckpointCreation(
      node: try store.checkpoints(of: id).node(id: checkpointID) ?? node, warnings: warnings)
  }

  /// The mode `request` resolves to for `record`, or the refusal.
  static func resolveMode(
    _ request: CheckpointModeRequest, for record: VMRecord
  ) throws(VMLabError) -> CheckpointMode {
    let live = record.features.contains(.checkpointLive)
    guard live || record.features.contains(.checkpointDisk) else {
      throw RunningVMErrors.capabilityMissing(.checkpoints, vm: record.id, profile: record.profile)
    }
    switch request {
    case .disk: return .disk
    case .live:
      guard live else {
        throw RunningVMErrors.capabilityMissing(
          Channel<any CheckpointProvider>(name: "checkpoints", features: [.checkpointLive]) {
            $0.checkpoints
          }, vm: record.id, profile: record.profile)
      }
      guard record.state.isLive else {
        throw VMLabError(
          code: .wrongState,
          message:
            "VM \(record.id) is \(record.state.rawValue); a live checkpoint needs it running",
          hint: "Start it first (vm_lifecycle start), or take a disk checkpoint.",
          data: Self.stateData(record))
      }
      return .live
    case .auto:
      guard record.state.isLive else { return .disk }
      guard live else {
        throw VMLabError(
          code: .wrongState,
          message:
            "VM \(record.id) is \(record.state.rawValue) and its plan has no checkpoint_live; "
            + "a disk checkpoint needs it stopped",
          hint:
            "Stop it first (vm_lifecycle stop) and take a disk checkpoint, or recreate the VM "
            + "with require: [\"checkpoint_live\"].",
          data: Self.stateData(record))
      }
      return .live
    }
  }

  /// Checkpoints work on a created, stopped, running or paused VM; a suspended VM must be started
  /// first (its disk is the resume point) and a broken one has nothing to save.
  static func checkCheckpointState(_ record: VMRecord, doing what: String) throws(VMLabError) {
    guard record.state == .suspended || record.state == .broken else { return }
    throw VMLabError(
      code: .wrongState,
      message: "VM \(record.id) is \(record.state.rawValue); cannot \(what) in that state",
      hint: record.state == .suspended
        ? "Start it first (vm_lifecycle start)." : "Kill or destroy it (vm_lifecycle).",
      data: stateData(record))
  }

  static func stateData(_ record: VMRecord) -> [String: JSONValue] {
    [
      "vm": .string(record.id), "state": .string(record.state.rawValue),
      "legalActions": .array(Lifecycle.legalActions(in: record.state).map { .string($0.rawValue) }),
    ]
  }

  /// `checkpoint_stop`: a temporary live checkpoint, then the engine ends; the VM is `suspended`
  /// and its next start resumes from the checkpoint.
  func checkpointStop(_ record: VMRecord, with backend: any Backend) async throws(VMLabError) {
    guard record.features.contains(.checkpointLive) else {
      throw RunningVMErrors.capabilityMissing(
        Channel<any CheckpointProvider>(name: "checkpoints", features: [.checkpointLive]) {
          $0.checkpoints
        }, vm: record.id, profile: record.profile)
    }
    let stamp = Date().formatted(
      .iso8601.year().month().day().time(includingFractionalSeconds: false)
    )
    .replacingOccurrences(of: ":", with: "")
    let made = try await takeCheckpoint(
      record.id, name: "suspend-\(stamp)", mode: .live, manifest: false,
      note: "saved by checkpoint_stop", temporary: true)
    try await backend.kill(record)
    try store.updateCheckpoints(of: record.id) {
      (tree: inout CheckpointTree, _) throws(VMLabError) in
      tree.resume = made.node.id
    }
  }

  /// After a suspended VM's engine started: restores the live checkpoint it resumes from. On
  /// failure the guest is killed again and the VM stays suspended.
  func resumeSuspended(
    _ record: VMRecord, runtime: VMRuntime, with backend: any Backend
  ) async throws(VMLabError) {
    guard let resume = try store.checkpoints(of: record.id).resume else { return }
    var started = record
    started.state = .running
    started.runtime = runtime
    do {
      try await backend.checkpoints(started).restore(id: resume, mode: .live)
    } catch {
      try? await backend.kill(started)
      throw error
    }
    try store.updateCheckpoints(of: record.id) {
      (tree: inout CheckpointTree, _) throws(VMLabError) in
      tree.resume = nil
      tree.current = resume
    }
  }
}
