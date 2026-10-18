import Foundation

/// One image `prune` removed or would remove.
public struct PrunedImage: Codable, Sendable, Hashable {
  public var name: String
  public var bytes: Int64
}

extension ImageStore {
  /// Appendix G: a pull of more than 10 GB needs `confirm: true`.
  public static let confirmAboveBytes: Int64 = 10 << 30

  /// `confirm_required` when pulling `name` would download more than 10 GB and `confirm` is
  /// false; nothing for an image already pulled or of unknown size.
  public nonisolated func checkPullSize(_ name: String, confirm: Bool) throws(VMLabError) {
    guard !confirm, pulled(name) == nil, let entry = catalogue.image(named: name),
      let bytes = entry.approxBytes, bytes > Self.confirmAboveBytes
    else { return }
    let gb = (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(0)))
    throw VMLabError(
      code: .confirmRequired,
      message: "Pulling \(name) downloads about \(gb) GB (more than 10 GB) into \(directory.path)",
      hint: "Call again with confirm: true to pull it, after checking the free disk space.",
      data: ["bytes": .number(Double(bytes)), "name": .string(name)])
  }

  /// The image names `records` use: each VM's `image`. Templates (R-804) add theirs to this set.
  public static func references(_ records: [VMRecord]) -> Set<String> {
    Set(records.compactMap(\.image))
  }

  /// Pulled or registered images no name in `referenced` uses, with their size on disk.
  public nonisolated func unreferenced(_ referenced: Set<String>) -> [PrunedImage] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.sorted().filter { !referenced.contains($0) && pulled($0) != nil }.map {
      PrunedImage(name: $0, bytes: Self.sizes(of: imageDirectory($0)).allocated)
    }
  }

  /// `images prune`: removes every image no name in `referenced` uses.
  public func prune(referenced: Set<String>) throws -> [PrunedImage] {
    let doomed = unreferenced(referenced)
    for image in doomed { try remove(image.name) }
    return doomed
  }

  /// Allocated and logical bytes of the regular files under `url`.
  nonisolated static func sizes(of url: URL) -> (allocated: Int64, logical: Int64) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
    guard
      let walker = FileManager.default.enumerator(
        at: url.resolvingSymlinksInPath(), includingPropertiesForKeys: keys, options: [])
    else { return (0, 0) }
    var allocated: Int64 = 0
    var logical: Int64 = 0
    for case let file as URL in walker {
      guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
      else { continue }
      logical += Int64(values.fileSize ?? 0)
      allocated += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
    return (allocated, logical)
  }
}
