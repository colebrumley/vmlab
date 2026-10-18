import Darwin
import Foundation
import VMLabCore

/// Clones of `vz-linux` guests (R-803): an APFS clone (`clonefile(2)`) of the source's raw
/// `disk.raw`, or of a checkpoint's disk clone at `<source>/checkpoints/<id>/disk.raw` (Appendix
/// F; R-608 makes those), then `create` writes the clone's seed with its own key and MAC. A raw
/// clone shares no file with its source, so the backing chain is empty.
extension VZBackend {
  public func clone(
    _ source: VMRecord, checkpoint: CheckpointNode?, into target: VMRecord
  ) async throws(VMLabError) -> [URL] {
    let from = store.directory(of: source.id)
    let disk =
      checkpoint.map { from.appending(path: "checkpoints/\($0.id)/disk.raw") }
      ?? from.appending(path: "disk.raw")
    guard FileManager.default.fileExists(atPath: disk.path) else {
      throw VMLabError.invalidRequest(
        field: checkpoint == nil ? "vm" : "from",
        reason: checkpoint == nil
          ? "VM \(source.id) has no disk.raw to clone"
          : "checkpoint \(checkpoint?.name ?? "") of \(source.id) has no disk clone",
        hint: "Clone from the current disk of a stopped VM.")
    }
    let to = store.directory(of: target.id).appending(path: "disk.raw")
    if clonefile(disk.path, to.path, 0) != 0 {
      do {
        try FileManager.default.copyItem(at: disk, to: to)
      } catch {
        throw VMLabError(
          code: .internal, message: "Cannot clone \(disk.path) to \(to.path): \(error)",
          hint: "Check free disk space and permissions under VMLAB_HOME.")
      }
    }
    let plan =
      source.plan
      ?? Plan(
        profile: source.profile, guest: source.guest, resources: source.resources,
        features: source.features, estimatedStartupSeconds: 0)
    try await create(target, plan: plan)
    return []
  }
}
