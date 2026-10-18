import Foundation

/// The kernel files of an image for direct kernel boot (R-305), kept in `images/<name>/kernel/`
/// and recorded in `image.json` under the `files` keys `kernel`, `initrd`, `systemMap` and
/// `config` (paths relative to the image directory).
public struct KernelFiles: Codable, Sendable, Hashable {
  public static let keys = ["kernel", "initrd", "systemMap", "config"]

  public var image: String
  /// The kernel release the files came from (`6.12.48+deb13-cloud-arm64`), when known.
  public var version: String?
  public var kernel: URL
  public var initrd: URL?
  public var systemMap: URL?
  public var config: URL?

  public init(
    image: String, version: String? = nil, kernel: URL, initrd: URL? = nil,
    systemMap: URL? = nil, config: URL? = nil
  ) {
    self.image = image
    self.version = version
    self.kernel = kernel
    self.initrd = initrd
    self.systemMap = systemMap
    self.config = config
  }

  /// Every file present, kernel first.
  public var all: [URL] { [kernel] + [initrd, systemMap, config].compactMap { $0 } }
}

extension ImageStore {
  /// The kernel files recorded for `name`, or nil when it has none.
  public nonisolated func kernel(of name: String) -> KernelFiles? {
    guard let record = pulled(name), let kernel = record.files["kernel"] else { return nil }
    let folder = imageDirectory(name)
    let url = { (key: String) in record.files[key].map { folder.appending(path: $0) } }
    return KernelFiles(
      image: name, version: record.kernelVersion, kernel: folder.appending(path: kernel),
      initrd: url("initrd"), systemMap: url("systemMap"), config: url("config"))
  }

  /// `images register <name> --kernel <path> [--initrd <path>]`: copies the files into
  /// `images/<name>/kernel/`. A pulled image keeps its disks and gains the kernel; otherwise a
  /// kernel-only image (`format: kernel`) is recorded for `guest`.
  public func registerKernel(
    _ name: String, kernel: URL, initrd: URL? = nil,
    guest: GuestSpec = GuestSpec(os: .linux, arch: .arm64)
  ) throws -> KernelFiles {
    try Self.validate(name)
    for (field, file) in [("kernel", kernel), ("initrd", initrd)] {
      guard let file else { continue }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw VMLabError.invalidRequest(
          field: field, reason: "\(file.path) is not a file",
          hint: "Give the host path of an existing \(field) image.")
      }
    }
    let folder = kernelDirectory(name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var copied: [String: URL] = ["kernel": kernel]
    if let initrd { copied["initrd"] = initrd }
    var files: [String: String] = [:]
    // Every new file is staged next to its target first and renamed over it only once all are
    // ready, so a failure keeps the kernel already registered whole.
    var staged: [(temp: URL, target: URL)] = []
    defer { for file in staged { try? FileManager.default.removeItem(at: file.temp) } }
    for (key, source) in copied {
      let target = folder.appending(path: Self.kernelFileNames[key]!)
      let temp = Self.stagingFile(for: target)
      staged.append((temp, target))
      try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: temp)
      if key == "kernel" { try Gzip.decompressInPlace(temp) }
      files[key] = "kernel/\(target.lastPathComponent)"
    }
    for file in staged { try Self.replace(file.target, with: file.temp) }
    var record =
      pulled(name)
      ?? PulledImage(
        name: name, guest: guest, source: kernel.path, format: .kernel, checksum: nil, files: [:],
        login: ImageLogin(user: "root"), pulledAt: now())
    for key in KernelFiles.keys { record.files[key] = nil }
    record.files.merge(files) { $1 }
    record.kernelVersion = nil
    try write(record)
    guard let result = self.kernel(of: name) else {
      throw VMLabError(code: .internal, message: "The registered kernel did not record.", hint: "")
    }
    return result
  }

  /// `images extract-kernel <image>`: copies the newest kernel in `/boot` of a pulled Linux
  /// image, with its initrd, `System.map` and `config`, into `images/<image>/kernel/`. The ext4
  /// root is read by `Ext4Volume` (macOS has no ext4 driver, so `hdiutil` cannot mount it); an
  /// image without `disk.raw` is converted to a temporary raw file first.
  public func extractKernel(_ name: String) throws -> KernelFiles {
    try Self.validate(name)
    guard var record = pulled(name) else {
      throw VMLabError(
        code: .imageNotFound, message: "The image \(name) is not pulled.",
        hint: "Run `vmlab images pull \(name)` first.", data: ["name": .string(name)])
    }
    guard record.guest.os == .linux else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "\(name) is not a Linux image",
        hint: "Extract kernels from Linux images only.")
    }
    let folder = imageDirectory(name)
    var temporary: URL?
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    let raw: URL
    if let file = record.files[ImageFormat.raw.rawValue] {
      raw = folder.appending(path: file)
    } else if let file = record.files[ImageFormat.qcow2.rawValue] {
      let tool = try locate("qemu-img", fix: "brew install qemu")
      let target = folder.appending(path: "extract.raw")
      temporary = target
      try convertToRaw(tool, folder.appending(path: file), target)
      raw = target
    } else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "\(name) has no disk to extract a kernel from",
        hint: "Pull a Linux cloud image, or register a kernel with images register.")
    }

    let found = try Self.findBoot(in: raw)
    let out = kernelDirectory(name)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for key in KernelFiles.keys { record.files[key] = nil }
    for (key, source) in found.files {
      let target = out.appending(path: Self.kernelFileNames[key]!)
      try found.volume.copy(source, to: target)
      if key == "kernel" { try Gzip.decompressInPlace(target) }
      record.files[key] = "kernel/\(target.lastPathComponent)"
    }
    record.kernelVersion = found.version
    try write(record)
    guard let result = kernel(of: name) else {
      throw VMLabError(code: .internal, message: "The extracted kernel did not record.", hint: "")
    }
    return result
  }

  /// `boot` ready to start: a kernel boot without a kernel path takes `image`'s kernel files (and
  /// initrd, unless one was given), extracting them from the pulled image the first time; every
  /// host path the mode uses must be a readable file. Both engines start from this (R-305, R-604).
  public func resolvingBoot(_ boot: BootSpec?, image: String?) throws(VMLabError) -> BootSpec {
    var boot = boot ?? BootSpec()
    if boot.mode == .kernel, boot.kernel == nil {
      guard let image else {
        throw VMLabError.invalidRequest(
          field: "boot.kernel", reason: "kernel boot needs a kernel path or an image",
          hint: "Set boot.kernel, or name an image whose kernel vmlab can extract.")
      }
      let files: KernelFiles
      do {
        files = try kernel(of: image) ?? extractKernel(image)
      } catch let error as VMLabError {
        throw error
      } catch {
        throw VMLabError(
          code: .internal, message: "Cannot extract the kernel of \(image): \(error)",
          hint: "Register a kernel with images register.", data: ["image": .string(image)])
      }
      boot.kernel = files.kernel.path
      if boot.initrd == nil { boot.initrd = files.initrd?.path }
    }
    let paths: [(String, String?)] = [
      ("boot.kernel", boot.mode == .kernel ? boot.kernel : nil),
      ("boot.initrd", boot.mode == .kernel ? boot.initrd : nil),
      ("boot.dtb", boot.mode == .kernel ? boot.dtb : nil),
      ("boot.firmware", boot.mode == .firmware ? boot.firmware : nil),
      ("boot.binary", boot.mode == .binary ? boot.binary : nil),
    ]
    for case (let field, let path?) in paths
    where !FileManager.default.isReadableFile(atPath: path) {
      throw VMLabError.invalidRequest(
        field: field, reason: "\(path) is not a readable file",
        hint: "Give the absolute host path of an existing file.")
    }
    return boot
  }

  public nonisolated func kernelDirectory(_ name: String) -> URL {
    imageDirectory(name).appending(path: "kernel")
  }

  static let kernelFileNames = [
    "kernel": "vmlinuz", "initrd": "initrd.img", "systemMap": "System.map", "config": "config",
  ]

  /// The newest kernel on any ext4 partition of `raw` (in `/boot`, or at the root of a separate
  /// boot partition) and its companions.
  static func findBoot(
    in raw: URL
  ) throws(VMLabError) -> (volume: Ext4Volume, version: String, files: [String: Ext4Volume.Inode]) {
    var offsets = (try? Ext4Volume.partitions(of: raw).map(\.offset)) ?? []
    if offsets.isEmpty { offsets = [0] }
    for offset in offsets {
      guard let volume = try? Ext4Volume(image: raw, offset: offset) else { continue }
      for directory in ["/boot", "/"] {
        guard let boot = try? volume.lookup(directory), boot.kind == .directory,
          let entries = try? volume.entries(of: boot)
        else { continue }
        let byName = Dictionary(entries.map { ($0.name, $0.inode) }) { first, _ in first }
        let versions = entries.compactMap { entry -> String? in
          for prefix in ["vmlinuz-", "vmlinux-", "Image-"] where entry.name.hasPrefix(prefix) {
            return String(entry.name.dropFirst(prefix.count))
          }
          return nil
        }
        guard
          let version = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending })
        else { continue }
        var files: [String: Ext4Volume.Inode] = [:]
        let names = [
          "kernel": ["vmlinuz-", "vmlinux-", "Image-"], "initrd": ["initrd.img-", "initramfs-"],
          "systemMap": ["System.map-"], "config": ["config-"],
        ]
        for (key, prefixes) in names {
          for prefix in prefixes where byName[prefix + version] != nil {
            let path = (directory == "/" ? "/" : directory + "/") + prefix + version
            if let inode = try? volume.lookup(path), inode.kind == .file {
              files[key] = inode
              break
            }
          }
        }
        if files["kernel"] != nil { return (volume, version, files) }
      }
    }
    throw Ext4Volume.error("no kernel (vmlinuz-*) in /boot of \(raw.lastPathComponent)")
  }
}
