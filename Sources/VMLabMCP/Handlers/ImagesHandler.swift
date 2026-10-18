import Foundation
import VMLabCore

/// `images`: list, pull and remove over `ImageStore` (R-300); `pull` reports progress while it
/// downloads. extract_kernel and the kernel form of register are R-305's; registering a disk or
/// an IPSW is R-1002's; prune and the confirm gate on large pulls are R-1003's; template_create
/// (R-804) copies a stopped VM's disk into a template image.
struct ImagesHandler: ToolHandler {
  var spec: ToolSpec { .images }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let action = try arguments.string("action") ?? ""
    switch action {
    case "list":
      return ToolResult(["images": .array(context.images.list().map { Self.row($0, context) })])
    case "pull":
      let name = try Self.name(arguments)
      let result = try await LongOperation.pull(
        name, confirm: try arguments.bool("confirm"), context: context)
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
    case "extract_kernel":
      let name = try Self.name(arguments)
      let images = context.images
      let files = try await context.progress.during(
        "extracting the kernel of \(name)", every: context.heartbeat
      ) { () throws(VMLabError) -> KernelFiles in
        try await LongOperation.typed("images extract_kernel \(name)") {
          try await images.extractKernel(name)
        }
      }
      return Self.kernelResult(files, context)
    case "template_create":
      let name = try Self.name(arguments)
      guard let vm = try arguments.string("vm"), !vm.isEmpty else {
        throw VMLabError.invalidRequest(
          field: "vm", reason: "template_create needs the stopped VM to copy",
          hint: "Add vm: the VM's name or id.")
      }
      let record = try context.store.find(vm)
      let directory = context.store.directory(of: record.id)
      let images = context.images
      let image = try await context.progress.during(
        "copying \(record.id) into template \(name)", every: context.heartbeat
      ) { () throws(VMLabError) -> PulledImage in
        try await images.createTemplate(name, from: record, vmDirectory: directory)
      }
      let folder = images.imageDirectory(name)
      return ToolResult([
        "name": .string(name), "path": .string(folder.path),
        "files": .array(
          image.files.values.sorted().map { .string(folder.appending(path: $0).path) }),
        "vm": .object(["id": .string(record.id), "name": .string(record.name)]),
      ])
    case "register" where try arguments.string("kernel") != nil:
      let name = try Self.name(arguments)
      guard try arguments.string("path") == nil else {
        throw VMLabError.invalidRequest(
          field: "path", reason: "register takes a kernel or a disk path, not both",
          hint: "Register the kernel and the disk under separate calls.")
      }
      let policy = PathPolicy.load(home: context.home)
      let kernel = try policy.check(try arguments.string("kernel") ?? "", field: "kernel")
      let initrd = try arguments.string("initrd").map { (value) throws(VMLabError) in
        try policy.check(value, field: "initrd")
      }
      let guest = GuestSpec(
        os: .linux, arch: GuestSpec.Arch(rawValue: try arguments.string("arch") ?? "arm64"))
      let images = context.images
      let files = try await LongOperation.typed("images register \(name)") {
        try await images.registerKernel(name, kernel: kernel, initrd: initrd, guest: guest)
      }
      return Self.kernelResult(files, context)
    case "register":
      return try await Self.register(arguments, context: context)
    case "prune":
      return try await Self.prune(confirm: try arguments.bool("confirm"), context: context)
    default:
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(action) is not an images action",
        hint: "Use list, pull, remove, register, extract_kernel, template_create or prune.")
    }
  }

  /// `register` with `path`: a disk image (`guest`, `arch`, `format`) or an `.ipsw`.
  static func register(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    guard let path = try arguments.string("path"), !path.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "path", reason: "register needs path (a disk image or .ipsw) or kernel",
        hint: "Give path with the host path of a raw or qcow2 disk, or of an .ipsw.")
    }
    let file = try PathPolicy.load(home: context.home).check(path, field: "path")
    let images = context.images
    let record: PulledImage
    if file.pathExtension.lowercased() == "ipsw" {
      let name = try arguments.string("name") ?? "macos-ipsw"
      record = try await context.progress.during(
        "installing \(file.lastPathComponent) with tart create", every: context.heartbeat
      ) { () throws(VMLabError) -> PulledImage in
        try await LongOperation.typed("images register \(name)") {
          try await images.registerIPSW(name, ipsw: file)
        }
      }
    } else {
      let name = try Self.name(arguments)
      let os =
        try arguments.string("guest").map { value throws(VMLabError) -> GuestSpec.OS in
          guard let os = GuestSpec.OS(rawValue: value) else {
            throw VMLabError.invalidRequest(
              field: "guest", reason: "\(value) is not a guest OS", hint: "Use linux.")
          }
          return os
        } ?? .linux
      let guest = GuestSpec(
        os: os, arch: GuestSpec.Arch(rawValue: try arguments.string("arch") ?? "arm64"))
      let format = try arguments.string("format").map { value throws(VMLabError) -> ImageFormat in
        guard let format = ImageFormat(rawValue: value), format == .raw || format == .qcow2 else {
          throw VMLabError.invalidRequest(
            field: "format", reason: "\(value) is not a disk format", hint: "Use raw or qcow2.")
        }
        return format
      }
      record = try await context.progress.during(
        "registering \(file.lastPathComponent)", every: context.heartbeat
      ) { () throws(VMLabError) -> PulledImage in
        try await LongOperation.typed("images register \(name)") {
          try await images.registerDisk(name, disk: file, guest: guest, format: format)
        }
      }
    }
    let folder = images.imageDirectory(record.name)
    var object: [String: JSONValue] = [
      "name": .string(record.name), "path": .string(folder.path),
      "guest": .string(record.guest.os.rawValue), "arch": .string(record.guest.arch.rawValue),
      "format": .string(record.format.rawValue),
      "files": .array(
        record.files.values.sorted().map { .string(folder.appending(path: $0).path) }),
    ]
    if let vm = record.tartVM { object["tartVM"] = .string(vm) }
    var warnings: [String] = []
    if record.format == .tart {
      warnings.append(
        "macOS is installed but not set up: run `tart run \(record.tartVM ?? "")`, finish Setup "
          + "Assistant with the account admin/admin and turn on Remote Login (docs/AGENT.md)")
    }
    return ToolResult(object, warnings: warnings)
  }

  /// `prune`: removes every image no VM uses. If a VM record cannot be read nothing is removed,
  /// since its image is unknown; more than 10 GB at once needs `confirm`.
  static func prune(confirm: Bool, context: ToolContext) async throws(VMLabError) -> ToolResult {
    let listed = try context.store.list()
    let images = context.images
    if !listed.unreadable.isEmpty {
      let ids = listed.unreadable.keys.sorted()
      return ToolResult(
        ["removed": .array([]), "bytesFreed": .number(0)],
        warnings: [
          "kept every image: the records of \(ids.joined(separator: ", ")) cannot be read, so "
            + "the images they use are unknown"
        ])
    }
    let referenced = ImageStore.references(listed.records)
    let doomed = images.unreferenced(referenced)
    let total = doomed.reduce(Int64(0)) { $0 + $1.bytes }
    if total > ImageStore.confirmAboveBytes, !confirm {
      let gb = (Double(total) / 1e9).formatted(.number.precision(.fractionLength(1)))
      throw VMLabError(
        code: .confirmRequired,
        message: "Pruning removes \(doomed.count) images, \(gb) GB: "
          + doomed.map(\.name).joined(separator: ", "),
        hint: "Call again with confirm: true to remove them.",
        data: [
          "bytes": .number(Double(total)), "names": .array(doomed.map { .string($0.name) }),
        ])
    }
    let removed = try await LongOperation.typed("images prune") {
      try await images.prune(referenced: referenced)
    }
    return ToolResult([
      "removed": .array(removed.map { .string($0.name) }),
      "bytesFreed": .number(Double(removed.reduce(Int64(0)) { $0 + $1.bytes })),
      "kept": .array(referenced.sorted().map { .string($0) }),
    ])
  }

  static func kernelResult(_ files: KernelFiles, _ context: ToolContext) -> ToolResult {
    var object: [String: JSONValue] = [
      "name": .string(files.image),
      "path": .string(context.images.kernelDirectory(files.image).path),
      "files": .array(files.all.map { .string($0.path) }),
      "kernel": .string(files.kernel.path),
      "initrd": files.initrd.map { .string($0.path) } ?? .null,
    ]
    if let version = files.version { object["version"] = .string(version) }
    return ToolResult(object)
  }

  static func name(_ arguments: ToolArguments) throws(VMLabError) -> String {
    guard let name = try arguments.string("name"), !name.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "name is required for this action",
        hint: "Add the image name; images list shows them.")
    }
    try ImageStore.checkName(name, field: "name")
    return name
  }

  static func row(_ listing: ImageListing, _ context: ToolContext) -> JSONValue {
    var row: [String: JSONValue] = [
      "name": .string(listing.name), "guest": .string(listing.guest.os.rawValue),
      "arch": .string(listing.guest.arch.rawValue), "format": .string(listing.format.rawValue),
      "pulled": .bool(listing.pulled != nil), "template": .bool(listing.pulled?.template != nil),
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
