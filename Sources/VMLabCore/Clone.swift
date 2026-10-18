import Foundation

extension VMManager {
  /// A new VM `name` (default: its id) from `vm`'s current disk or from its checkpoint `from`
  /// (R-803): the same plan, profile, image and network, a new id (so a new MAC) and a new SSH key,
  /// in state `created`. The engine makes the disk (`Backend.clone`); the files it reads through
  /// are recorded as the clone's `backingChain`. A current-disk clone needs the source stopped
  /// (its disk is not consistent while the guest runs); a checkpoint clone works in any state but
  /// `broken`. On failure nothing of the clone is left.
  public func clone(
    _ vm: String, name: String? = nil, from checkpoint: String? = nil
  ) async throws(VMLabError) -> VMRecord {
    let sourceID = try store.find(vm).id
    await acquire(sourceID)
    defer { release(sourceID) }
    let source = try store.load(id: sourceID)
    let backend = try backends.backend(for: source.profile)
    let node = try checkpoint.map { (name) throws(VMLabError) in
      try store.checkpoints(of: sourceID).resolve(name)
    }
    if source.state == .broken || (node == nil && source.state.isLive) {
      throw VMLabError(
        code: .wrongState,
        message: node == nil && source.state.isLive
          ? "VM \(sourceID) is \(source.state.rawValue); its current disk changes under a clone"
          : "VM \(sourceID) is broken; there is no disk to clone",
        hint: source.state.isLive
          ? "Stop it first (vm_lifecycle stop), or clone from a checkpoint (from)."
          : "Destroy it (vm_lifecycle destroy).",
        data: Self.stateData(source))
    }

    var draft = source
    draft.name = name ?? ""
    draft.state = .created
    draft.runtime = nil
    draft.checkpoints = []
    draft.createdAt = Date()
    draft.clonedFrom = CloneOrigin(vm: sourceID, checkpoint: node?.id, checkpointName: node?.name)
    draft.backingChain = nil
    // A clone is not in the source's fleet, and gets its own address on the source's segment.
    draft.segment = nil
    draft.fleet = nil
    var stored = try store.create(draft)
    let cloned: VMRecord
    do throws(VMLabError) {
      if let name = Self.segmentName(of: stored) {
        let attachment = try segments.join(name, vm: stored)
        stored = try store.update(id: stored.id) { $0.segment = attachment }
      }
      try await SSHKeys.generateDetached(
        in: store.directory(of: stored.id), comment: "vmlab-\(stored.id)", runner: keygen)
      let chain = try await backend.clone(source, checkpoint: node, into: stored)
      if Task.isCancelled { throw Self.cancelled("clone", vm: stored.id) }
      cloned = try store.update(id: stored.id) { $0.backingChain = chain.map(\.path) }
    } catch {
      let store = store
      let segments = segments
      let failed = stored
      await Task {
        try? await backend.destroy(failed)
        if let name = Self.segmentName(of: failed) { try? segments.leave(name, vm: failed.id) }
        try? store.remove(id: failed.id)
      }.value
      throw error
    }
    let what = node.map { "checkpoint \($0.name) (\($0.id))" } ?? "the current disk"
    await log(stored.id, "cloned from \(sourceID), \(what)")
    await log(sourceID, "cloned to \(stored.id) from \(what)")
    return cloned
  }

  /// The VMs whose backing chain reads a file in `vm`'s directory: they break if it goes.
  public nonisolated func dependents(of vm: VMRecord) throws(VMLabError) -> [VMRecord] {
    let directory = store.directory(of: vm.id).standardizedFileURL.path + "/"
    return try store.list().records.filter { other in
      other.id != vm.id
        && (other.backingChain ?? []).contains {
          URL(filePath: $0).standardizedFileURL.path.hasPrefix(directory)
        }
    }
  }
}
