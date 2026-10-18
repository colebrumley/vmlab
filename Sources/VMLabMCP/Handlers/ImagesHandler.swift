import Foundation
import VMLabCore

/// `images`: list, pull and remove over `ImageStore` (R-300); `pull` reports progress while it
/// downloads. register (R-1002), template_create (R-804), prune (R-1003) and extract_kernel
/// (R-305) are refused until their items land.
struct ImagesHandler: ToolHandler {
  var spec: ToolSpec { .images }

  static let owners = [
    "register": "R-1002", "template_create": "R-804", "prune": "R-1003",
    "extract_kernel": "R-305",
  ]

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let action = try arguments.string("action") ?? ""
    switch action {
    case "list":
      return ToolResult(["images": .array(context.images.list().map { Self.row($0, context) })])
    case "pull":
      let name = try Self.name(arguments)
      let result = try await LongOperation.pull(name, context: context)
      let folder = context.images.imageDirectory(name)
      return ToolResult([
        "name": .string(name), "path": .string(folder.path),
        "bytes": .number(Double(Self.bytes(result.image, in: folder))),
        "cached": .bool(!result.changed),
        "files": .array(result.image.files.values.sorted().map { .string($0) }),
      ])
    case "remove":
      let name = try Self.name(arguments)
      let folder = context.images.imageDirectory(name)
      let freed = Self.directoryBytes(folder)
      let images = context.images
      let removed = try await LongOperation.typed("images remove \(name)") {
        try await images.remove(name)
      }
      return ToolResult([
        "removed": .array(removed ? [.string(name)] : []),
        "bytesFreed": .number(Double(removed ? freed : 0)),
      ])
    default:
      if let owner = Self.owners[action] {
        throw VMLabError.invalidRequest(
          field: "action", reason: "images \(action) is not built yet (\(owner))",
          hint: "list, pull and remove work now.")
      }
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(action) is not an images action",
        hint: "Use list, pull or remove.")
    }
  }

  static func name(_ arguments: ToolArguments) throws(VMLabError) -> String {
    guard let name = try arguments.string("name"), !name.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "name is required for this action",
        hint: "Add the image name; images list shows them.")
    }
    return name
  }

  static func row(_ listing: ImageListing, _ context: ToolContext) -> JSONValue {
    var row: [String: JSONValue] = [
      "name": .string(listing.name), "guest": .string(listing.guest.os.rawValue),
      "arch": .string(listing.guest.arch.rawValue), "format": .string(listing.format.rawValue),
      "pulled": .bool(listing.pulled != nil), "template": .bool(false),
    ]
    if let pulled = listing.pulled {
      let folder = context.images.imageDirectory(listing.name)
      row["path"] = .string(folder.path)
      row["bytes"] = .number(Double(bytes(pulled, in: folder)))
      row["pulledAt"] = .string(pulled.pulledAt.formatted(.iso8601))
    }
    return .object(row)
  }

  /// The size of the image's files (the disk images it records).
  static func bytes(_ image: PulledImage, in folder: URL) -> Int {
    Set(image.files.values).reduce(0) { total, file in
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: folder.appending(path: file).path)
      return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
    }
  }

  /// Every regular file under `folder`.
  static func directoryBytes(_ folder: URL) -> Int {
    guard
      let walker = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total = 0
    for case let url as URL in walker {
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
    }
    return total
  }
}
