import Foundation

extension ImageStore {
  /// The login user of a registered disk image: cloud-init creates it with the VM's key, so it
  /// works whatever accounts the image has (it needs cloud-init, as the catalogue images do).
  public static let registeredLogin = ImageLogin(user: "vmlab")

  /// The login of a macOS base built from an IPSW: the account docs/AGENT.md asks the user to
  /// create in Setup Assistant, matching the Tart images (Appendix H).
  public static let ipswLogin = ImageLogin(user: "admin", password: "admin")

  /// The format of the disk at `url` read from its header: qcow2 starts with `QFI\xfb`;
  /// anything else is taken as raw.
  public nonisolated static func detectFormat(of url: URL) -> ImageFormat {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .raw }
    defer { try? handle.close() }
    let magic = (try? handle.read(upToCount: 4)) ?? Data()
    return magic == Data([0x51, 0x46, 0x49, 0xFB]) ? .qcow2 : .raw
  }

  /// `images register <name> --disk <path> --guest linux --arch <arch> [--format raw|qcow2]`:
  /// copies the disk (an APFS clone where it can) into `images/<name>/` and records `image.json`
  /// with its SHA-256. The files both engines need are made with `qemu-img`: QEMU boots a qcow2
  /// overlay, so a raw disk gains `disk.qcow2`; an arm64 qcow2 gains `disk.raw` for VZ. A name
  /// already in use (pulled, registered or in the catalogue) is refused.
  public func registerDisk(
    _ name: String, disk: URL, guest: GuestSpec, format: ImageFormat? = nil
  ) throws -> PulledImage {
    try Self.validate(name)
    guard guest.os == .linux else {
      throw VMLabError.invalidRequest(
        field: "guest", reason: "a macOS base is a Tart VM, not a disk image",
        hint: "Register an installer with images register --ipsw <path> instead.")
    }
    try checkUnused(name)
    let source = try Self.regularFile(disk, field: "path")
    let detected = Self.detectFormat(of: source)
    if let format, format != detected {
      guard format == .raw || format == .qcow2 else {
        throw VMLabError.invalidRequest(
          field: "format", reason: "\(format.rawValue) is not a disk format",
          hint: "Use raw or qcow2.")
      }
      throw VMLabError.invalidRequest(
        field: "format",
        reason: "\(source.lastPathComponent) is \(detected.rawValue), not \(format.rawValue)",
        hint: "Leave format out to take the format the file's header says.")
    }
    let needsRaw = guest.arch == .arm64
    let qemuImg =
      detected == .raw || needsRaw ? try locate("qemu-img", fix: "brew install qemu") : nil

    let folder = imageDirectory(name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    do {
      let diskName = "disk.\(detected.rawValue)"
      let target = folder.appending(path: diskName)
      try FileManager.default.copyItem(at: source, to: target)
      var files = [detected.rawValue: diskName]
      if let qemuImg {
        if detected == .raw {
          try convert(
            qemuImg, target, from: .raw, to: folder.appending(path: "disk.qcow2"), as: .qcow2)
          files[ImageFormat.qcow2.rawValue] = "disk.qcow2"
        } else if needsRaw {
          try convertToRaw(qemuImg, target, folder.appending(path: "disk.raw"))
          files[ImageFormat.raw.rawValue] = "disk.raw"
        }
      }
      let digest = try ChecksumAlgorithm.sha256.hexDigest(ofFileAt: target)
      let record = PulledImage(
        name: name, guest: guest, source: source.path, format: detected,
        checksum: .init(algorithm: .sha256, value: digest), files: files,
        login: Self.registeredLogin, pulledAt: now())
      try write(record)
      return record
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }

  /// The Tart VM an IPSW for image `name` is installed into.
  public nonisolated static func tartVMName(forImage name: String) -> String {
    "vmlab-image-\(name)"
  }

  /// The argument vector of `tart` that installs `ipsw` into a new local VM `vm`.
  public nonisolated static func tartCreateArguments(ipsw: URL, vm: String) -> [String] {
    ["create", "--from-ipsw", ipsw.path, vm]
  }

  /// `images register [<name>] --ipsw <path>`: hands the IPSW to `tart create --from-ipsw`, which
  /// installs macOS into the local Tart VM `vmlab-image-<name>`, and records it as a `tart` image
  /// whose clones vz-macos boots. Setup Assistant (the admin account, Remote Login) is the
  /// user's attended step afterwards; docs/AGENT.md says how.
  public func registerIPSW(_ name: String, ipsw: URL) throws -> PulledImage {
    try Self.validate(name)
    try checkUnused(name)
    let source = try Self.regularFile(ipsw, field: "path")
    guard source.pathExtension.lowercased() == "ipsw" else {
      throw VMLabError.invalidRequest(
        field: "path", reason: "\(source.lastPathComponent) is not an .ipsw file",
        hint: "Give the path of a macOS restore image (.ipsw) for Apple silicon.")
    }
    let tool = try locate("tart", fix: "brew install cirruslabs/cli/tart")
    let vm = Self.tartVMName(forImage: name)
    let output = runner.run(tool, Self.tartCreateArguments(ipsw: source, vm: vm))
    guard let output, output.status == 0 else {
      throw VMLabError(
        code: .engineError, message: "tart create --from-ipsw \(source.lastPathComponent) failed",
        hint: "Check free disk space (the install needs about 60 GB) and that the IPSW is for "
          + "this Mac's macOS or older; run `tart delete \(vm)` before retrying.",
        data: ["engine": .string("tart"), "raw": .string(output?.output ?? "did not launch")])
    }
    try FileManager.default.createDirectory(
      at: imageDirectory(name), withIntermediateDirectories: true)
    let record = PulledImage(
      name: name, guest: GuestSpec(os: .macos, arch: .arm64), source: source.path,
      format: .tart, checksum: nil, files: [:], login: Self.ipswLogin, pulledAt: now(),
      tartVM: vm)
    try write(record)
    return record
  }

  /// Refuses a name that is already pulled, registered or in the catalogue.
  func checkUnused(_ name: String) throws {
    if catalogue.image(named: name) != nil || pulled(name) != nil {
      throw VMLabError.invalidRequest(
        field: "name", reason: "an image named \(name) already exists",
        hint: "Pick another name, or remove the image first with images remove \(name).")
    }
  }

  /// `url` resolved, when it names an existing regular file; else `invalid_request` on `field`.
  static func regularFile(_ url: URL, field: String) throws -> URL {
    let resolved = url.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw VMLabError.invalidRequest(
        field: field, reason: "\(url.path) is not a file",
        hint: "Give the host path of an existing file.")
    }
    return resolved
  }
}
