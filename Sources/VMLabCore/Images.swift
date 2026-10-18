import CryptoKit
import Foundation

/// The on-disk format of an image's disk, or a Tart VM for macOS (Appendix H).
public enum ImageFormat: String, Codable, Sendable, CaseIterable {
  /// `kernel`: a registered kernel (and initrd) with no disk, for direct kernel boot (R-305).
  case raw, qcow2, tart, kernel
}

/// The digest a catalogue's checksum file lists.
public enum ChecksumAlgorithm: String, Codable, Sendable {
  case sha256, sha512

  /// The hex digest of the file at `url`, read in chunks so a multi-gigabyte disk never sits in
  /// memory.
  public func hexDigest(ofFileAt url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    switch self {
    case .sha256:
      var hasher = SHA256()
      while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    case .sha512:
      var hasher = SHA512()
      while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
}

/// How to log in to a fresh guest of an image. `password: nil` means key only (cloud-init installs
/// the VM's key for `user`).
public struct ImageLogin: Codable, Sendable, Hashable {
  public var user: String
  public var password: String?

  public init(user: String, password: String? = nil) {
    self.user = user
    self.password = password
  }
}

/// One entry of the Appendix H catalogue.
public struct CatalogImage: Codable, Sendable, Hashable {
  public var name: String
  public var guest: GuestSpec
  /// What is downloaded (a disk image), or the Tart OCI reference for `format: tart`.
  public var url: String
  public var format: ImageFormat
  /// The `SHA512SUMS`/`SHA256SUMS` file beside `url`; nil for Tart images.
  public var checksumURL: URL?
  public var checksumAlgorithm: ChecksumAlgorithm?
  /// A qcow2 download is also converted to `disk.raw` with `qemu-img` (VZ boots raw only).
  public var convertToRaw: Bool
  public var login: ImageLogin
  /// About how many bytes a pull downloads, for the confirm gate (R-1003); nil when unknown.
  public var approxBytes: Int64?

  public init(
    name: String, guest: GuestSpec, url: String, format: ImageFormat, checksumURL: URL? = nil,
    checksumAlgorithm: ChecksumAlgorithm? = nil, convertToRaw: Bool = false, login: ImageLogin,
    approxBytes: Int64? = nil
  ) {
    self.name = name
    self.guest = guest
    self.url = url
    self.format = format
    self.checksumURL = checksumURL
    self.checksumAlgorithm = checksumAlgorithm
    self.convertToRaw = convertToRaw
    self.login = login
    self.approxBytes = approxBytes
  }

  enum CodingKeys: String, CodingKey {
    case name, guest, url, format, checksumURL, checksumAlgorithm, convertToRaw, login
    case approxBytes
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    guest = try container.decode(GuestSpec.self, forKey: .guest)
    url = try container.decode(String.self, forKey: .url)
    format = try container.decode(ImageFormat.self, forKey: .format)
    checksumURL = try container.decodeIfPresent(URL.self, forKey: .checksumURL)
    checksumAlgorithm = try container.decodeIfPresent(
      ChecksumAlgorithm.self, forKey: .checksumAlgorithm)
    convertToRaw = try container.decodeIfPresent(Bool.self, forKey: .convertToRaw) ?? false
    login = try container.decode(ImageLogin.self, forKey: .login)
    approxBytes = try container.decodeIfPresent(Int64.self, forKey: .approxBytes)
  }

  /// The name the checksum file lists the download under: the last path component of `url`.
  public var fileName: String { URL(string: url)?.lastPathComponent ?? url }
}

/// The images vmlab knows how to pull, decoded from JSON so a test can read a fixture catalogue.
public struct ImageCatalogue: Codable, Sendable, Hashable {
  public var images: [CatalogImage]

  public init(images: [CatalogImage]) { self.images = images }

  public func image(named name: String) -> CatalogImage? { images.first { $0.name == name } }

  public static func decode(_ data: Data) throws -> ImageCatalogue {
    try JSONDecoder().decode(ImageCatalogue.self, from: data)
  }

  /// Appendix H. Debian is pulled as qcow2 (about a seventh of the raw download) and converted to
  /// raw locally, which gives both formats.
  public static let builtin: ImageCatalogue = {
    do { return try decode(Data(builtinJSON.utf8)) } catch {
      preconditionFailure("the built-in image catalogue does not decode: \(error)")
    }
  }()

  static let builtinJSON = """
    {"images": [
      {"name": "debian-13-arm64", "guest": {"os": "linux", "arch": "arm64"},
       "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2",
       "format": "qcow2", "convertToRaw": true,
       "checksumURL": "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS",
       "checksumAlgorithm": "sha512", "login": {"user": "debian"}, "approxBytes": 340000000},
      {"name": "debian-13-amd64", "guest": {"os": "linux", "arch": "x86_64"},
       "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2",
       "format": "qcow2", "convertToRaw": false,
       "checksumURL": "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS",
       "checksumAlgorithm": "sha512", "login": {"user": "debian"}, "approxBytes": 345000000},
      {"name": "ubuntu-24.04-arm64", "guest": {"os": "linux", "arch": "arm64"},
       "url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img",
       "format": "qcow2", "convertToRaw": true,
       "checksumURL": "https://cloud-images.ubuntu.com/noble/current/SHA256SUMS",
       "checksumAlgorithm": "sha256", "login": {"user": "ubuntu"}, "approxBytes": 620000000},
      {"name": "ubuntu-24.04-amd64", "guest": {"os": "linux", "arch": "x86_64"},
       "url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img",
       "format": "qcow2", "convertToRaw": false,
       "checksumURL": "https://cloud-images.ubuntu.com/noble/current/SHA256SUMS",
       "checksumAlgorithm": "sha256", "login": {"user": "ubuntu"}, "approxBytes": 620000000},
      {"name": "macos-base", "guest": {"os": "macos", "arch": "arm64"},
       "url": "ghcr.io/cirruslabs/macos-tahoe-base:latest", "format": "tart",
       "login": {"user": "admin", "password": "admin"}, "approxBytes": 25000000000}
    ]}
    """
}

/// Parses `SHA512SUMS`/`SHA256SUMS` (`<hex>  <name>` or `<hex> *<name>`) into name → lowercase hex.
public enum ChecksumList {
  public static func parse(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
      guard parts.count == 2, parts[0].allSatisfy(\.isHexDigit) else { continue }
      var name = parts[1].trimmingCharacters(in: .whitespaces)
      if name.hasPrefix("*") { name.removeFirst() }
      result[name] = parts[0].lowercased()
    }
    return result
  }
}

/// `images/<name>/image.json`: what was pulled, from where, and which files hold it.
public struct PulledImage: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1

  public struct Checksum: Codable, Sendable, Hashable {
    public var algorithm: ChecksumAlgorithm
    public var value: String

    public init(algorithm: ChecksumAlgorithm, value: String) {
      self.algorithm = algorithm
      self.value = value
    }
  }

  public var schemaVersion: Int
  public var name: String
  public var guest: GuestSpec
  public var source: String
  public var format: ImageFormat
  /// Of the downloaded file; nil for Tart images.
  public var checksum: Checksum?
  /// Format → file name inside the image directory (`disk.qcow2`, `disk.raw`).
  public var files: [String: String]
  public var login: ImageLogin
  public var pulledAt: Date
  /// The release of the kernel in `files["kernel"]` when it was extracted (R-305).
  public var kernelVersion: String?
  /// Set when the image is a template made from a VM (R-804); additive, schema 1 still.
  public var template: TemplateInfo?
  /// For a Tart image, the name `tart clone` takes as its source: the OCI reference that was
  /// pulled, or the local Tart VM an IPSW was installed into (R-1002).
  public var tartVM: String?

  public init(
    name: String, guest: GuestSpec, source: String, format: ImageFormat, checksum: Checksum?,
    files: [String: String], login: ImageLogin, pulledAt: Date, kernelVersion: String? = nil,
    template: TemplateInfo? = nil, tartVM: String? = nil
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.name = name
    self.guest = guest
    self.source = source
    self.format = format
    self.checksum = checksum
    self.files = files
    self.login = login
    self.kernelVersion = kernelVersion
    self.template = template
    self.tartVM = tartVM
    // Whole seconds, so the record equals what image.json (ISO 8601) reads back.
    self.pulledAt = Date(timeIntervalSince1970: pulledAt.timeIntervalSince1970.rounded(.down))
  }
}

/// One row of `images list`: every catalogue image, and anything pulled that the catalogue lacks.
public struct ImageListing: Codable, Sendable, Hashable {
  public var name: String
  public var guest: GuestSpec
  public var format: ImageFormat
  public var pulled: PulledImage?
}

/// The result of a pull: the record, and whether anything was downloaded or converted.
public struct PullResult: Codable, Sendable, Hashable {
  public var image: PulledImage
  public var changed: Bool
}

/// Fetches image files. `URLSessionDownloader` does it for real; tests use files on disk.
public protocol ImageDownloading: Sendable {
  func data(from url: URL) async throws -> Data
  /// Downloads `url` to `destination`, which does not exist yet.
  func download(from url: URL, to destination: URL) async throws
}

/// Downloads over HTTPS with `URLSession`; a non-2xx status is an error.
public struct URLSessionDownloader: ImageDownloading {
  public init() {}

  public func data(from url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    try Self.check(response, url)
    return data
  }

  public func download(from url: URL, to destination: URL) async throws {
    let (temporary, response) = try await URLSession.shared.download(from: url)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try Self.check(response, url)
    try FileManager.default.moveItem(at: temporary, to: destination)
  }

  static func check(_ response: URLResponse, _ url: URL) throws {
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw ImageStore.downloadError(url, "HTTP status \(http.statusCode)")
    }
  }
}

/// `VMLAB_HOME/images/`: pulls, lists and removes images. An actor so two pulls of one image in a
/// process never write the same files.
public actor ImageStore {
  public nonisolated let directory: URL
  public nonisolated let catalogue: ImageCatalogue
  let downloader: any ImageDownloading
  let runner: any CommandRunning
  let searchPaths: [String]
  let now: @Sendable () -> Date

  public init(
    home: URL,
    catalogue: ImageCatalogue = .builtin,
    downloader: any ImageDownloading = URLSessionDownloader(),
    runner: any CommandRunning = ProcessRunner(),
    searchPaths: [String] = HostProbe.defaultSearchPaths(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directory = home.appending(path: "images")
    self.catalogue = catalogue
    self.downloader = downloader
    self.runner = runner
    self.searchPaths = searchPaths
    self.now = now
  }

  /// `VMLAB_HOME`, or `~/.vmlab` when it is unset or empty.
  public static func defaultHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let home = environment["VMLAB_HOME"], !home.isEmpty { return URL(filePath: home) }
    return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vmlab")
  }

  /// `images/<name>/`. Callers pass a name `isImageName` accepts (`checkName` at every entry
  /// point); `pulled` refuses any other.
  public nonisolated func imageDirectory(_ name: String) -> URL { directory.appending(path: name) }

  /// The record of a pulled image, or nil when it is not pulled. Nil too for a name that is not a
  /// single path component, and for a record whose `files` name anything but a file inside the
  /// image's directory (canonical, symlinks resolved), so an `image.json` cannot point an engine
  /// at another host file (CR-4).
  public nonisolated func pulled(_ name: String) -> PulledImage? {
    guard Self.isImageName(name) else { return nil }
    let folder = imageDirectory(name)
    guard let data = try? Data(contentsOf: folder.appending(path: "image.json")) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let record = try? decoder.decode(PulledImage.self, from: data),
      record.files.values.allSatisfy({ Self.isContained($0, in: folder) })
    else { return nil }
    return record
  }

  /// Whether `name` can name an image: one non-empty path component, not `.` or `..`.
  public static func isImageName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }

  /// `invalid_request` on `field` unless `isImageName(name)`.
  public static func checkName(_ name: String, field: String) throws(VMLabError) {
    guard isImageName(name) else {
      throw VMLabError.invalidRequest(
        field: field, reason: "\(name) is not an image name",
        hint: "Use a name from images list.")
    }
  }

  /// Whether the relative path `file` stays inside `folder` once canonical.
  static func isContained(_ file: String, in folder: URL) -> Bool {
    guard !file.isEmpty, !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else {
      return false
    }
    let root = PathPolicy.canonical(folder.path)
    let resolved = PathPolicy.canonical(folder.appending(path: file).path)
    return resolved != root && PathPolicy.isInside(resolved, root)
  }

  /// The guest an image runs: its pulled record's, else its catalogue entry's; nil when unknown.
  public nonisolated func guest(of name: String) -> GuestSpec? {
    pulled(name)?.guest ?? catalogue.image(named: name)?.guest
  }

  /// Every catalogue image with its pulled record, then pulled images the catalogue lacks.
  public nonisolated func list() -> [ImageListing] {
    var rows = catalogue.images.map {
      ImageListing(name: $0.name, guest: $0.guest, format: $0.format, pulled: pulled($0.name))
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names.sorted() where catalogue.image(named: name) == nil {
      if let record = pulled(name) {
        rows.append(
          ImageListing(name: name, guest: record.guest, format: record.format, pulled: record))
      }
    }
    return rows
  }

  /// Deletes `images/<name>/`; false when it was not there.
  @discardableResult
  public func remove(_ name: String) throws -> Bool {
    try Self.validate(name)
    let url = imageDirectory(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    try FileManager.default.removeItem(at: url)
    return true
  }

  /// Downloads `name` into `images/<name>/`, verifies its checksum, converts qcow2 to raw when the
  /// catalogue asks, and writes `image.json`. A no-op when the pulled file still matches the
  /// published checksum (or the checksum file cannot be fetched and the image is complete).
  public func pull(_ name: String) async throws -> PullResult {
    guard let entry = catalogue.image(named: name) else {
      throw VMLabError(
        code: .imageNotFound, message: "No image named \(name) in the catalogue",
        hint: "Pick one of the available names, or run images list",
        data: [
          "name": .string(name), "available": .array(catalogue.images.map { .string($0.name) }),
        ])
    }
    if entry.format == .tart { return try pullTart(entry) }
    guard let checksumURL = entry.checksumURL, let algorithm = entry.checksumAlgorithm,
      let source = URL(string: entry.url)
    else {
      throw VMLabError(
        code: .internal, message: "Catalogue entry \(name) has no source or checksum",
        hint: "This is a bug in the catalogue", data: ["id": .string("catalogue-\(name)")])
    }

    let wantsRaw = entry.format == .qcow2 && entry.convertToRaw
    let qemuImg = wantsRaw ? try locate("qemu-img", fix: "brew install qemu") : nil
    let folder = imageDirectory(name)
    let existing = pulled(name)
    let expected: String
    do {
      let sums = ChecksumList.parse(
        String(decoding: try await downloader.data(from: checksumURL), as: UTF8.self))
      guard let value = sums[entry.fileName] else {
        throw Self.downloadError(checksumURL, "\(entry.fileName) is not listed")
      }
      expected = value
    } catch {
      if let existing, isComplete(existing, entry) {
        return PullResult(image: existing, changed: false)
      }
      throw error
    }

    let diskName = "disk.\(entry.format.rawValue)"
    let disk = folder.appending(path: diskName)
    if let existing, existing.checksum?.value == expected, isComplete(existing, entry),
      (try? algorithm.hexDigest(ofFileAt: disk)) == expected
    {
      return PullResult(image: existing, changed: false)
    }

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let partial = folder.appending(path: diskName + ".partial")
    try? FileManager.default.removeItem(at: partial)
    do {
      try await downloader.download(from: source, to: partial)
    } catch let error as VMLabError {
      throw error
    } catch {
      throw Self.downloadError(source, error.localizedDescription)
    }
    let actual = try algorithm.hexDigest(ofFileAt: partial)
    guard actual == expected else {
      try? FileManager.default.removeItem(at: partial)
      throw VMLabError(
        code: .engineError,
        message: "\(entry.fileName) does not match its published \(algorithm.rawValue)",
        hint: "Pull again; if it keeps failing the mirror is serving a stale or damaged file",
        data: [
          "engine": .string("download"),
          "raw": .string("expected \(expected), got \(actual)"),
        ])
    }
    try Self.replace(disk, with: partial)
    try Data("\(expected)  \(entry.fileName)\n".utf8).write(to: folder.appending(path: "checksums"))

    var files = [entry.format.rawValue: diskName]
    if let qemuImg {
      try convertToRaw(qemuImg, disk, folder.appending(path: "disk.raw"))
      files[ImageFormat.raw.rawValue] = "disk.raw"
    }
    let record = PulledImage(
      name: name, guest: entry.guest, source: entry.url, format: entry.format,
      checksum: .init(algorithm: algorithm, value: expected), files: files, login: entry.login,
      pulledAt: now())
    try write(record)
    return PullResult(image: record, changed: true)
  }

  // MARK: Steps

  nonisolated func isComplete(_ record: PulledImage, _ entry: CatalogImage) -> Bool {
    let wanted =
      entry.format == .qcow2 && entry.convertToRaw ? ["qcow2", "raw"] : [entry.format.rawValue]
    return wanted.allSatisfy { format in
      record.files[format].map {
        FileManager.default.fileExists(atPath: imageDirectory(record.name).appending(path: $0).path)
      } ?? false
    }
  }

  func convertToRaw(_ tool: String, _ qcow2: URL, _ raw: URL) throws {
    try convert(tool, qcow2, from: .qcow2, to: raw, as: .raw)
  }

  /// `qemu-img convert` from `input` to `output` through a `.partial` file.
  func convert(
    _ tool: String, _ input: URL, from: ImageFormat, to output: URL, as format: ImageFormat
  ) throws {
    let partial = output.deletingLastPathComponent().appending(
      path: output.lastPathComponent + ".partial")
    try? FileManager.default.removeItem(at: partial)
    let result = runner.run(
      tool,
      ["convert", "-f", from.rawValue, "-O", format.rawValue, input.path, partial.path])
    guard let result, result.status == 0 else {
      try? FileManager.default.removeItem(at: partial)
      throw VMLabError(
        code: .engineError, message: "qemu-img could not convert the image to \(format.rawValue)",
        hint: "Check free disk space and that qemu-img runs, then pull again",
        data: ["engine": .string("qemu-img"), "raw": .string(result?.output ?? "did not launch")])
    }
    try Self.replace(output, with: partial)
  }

  /// `tart pull <ref>` into Tart's cache; the record names the ref as the Tart VM to clone.
  func pullTart(_ entry: CatalogImage) throws -> PullResult {
    if let existing = pulled(entry.name), existing.tartVM != nil {
      return PullResult(image: existing, changed: false)
    }
    let tool = try locate("tart", fix: "brew install cirruslabs/cli/tart")
    let output = runner.run(tool, ["pull", entry.url])
    guard let output, output.status == 0 else {
      throw VMLabError(
        code: .engineError, message: "tart pull \(entry.url) failed",
        hint: "Check the network and free disk space, then pull again",
        data: ["engine": .string("tart"), "raw": .string(output?.output ?? "did not launch")])
    }
    try FileManager.default.createDirectory(
      at: imageDirectory(entry.name), withIntermediateDirectories: true)
    let record = PulledImage(
      name: entry.name, guest: entry.guest, source: entry.url, format: .tart, checksum: nil,
      files: [:], login: entry.login, pulledAt: now(), tartVM: entry.url)
    try write(record)
    return PullResult(image: record, changed: true)
  }

  func locate(_ tool: String, fix: String) throws -> String {
    for directory in searchPaths {
      let path = URL(filePath: directory).appending(path: tool).path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    throw VMLabError(
      code: .hostMissingTool, message: "\(tool) is not installed", hint: "Run: \(fix)",
      data: ["tool": .string(tool), "fix": .string(fix)])
  }

  func write(_ record: PulledImage) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(
      to: imageDirectory(record.name).appending(path: "image.json"), options: .atomic)
  }

  /// A fresh path next to `target` (same directory, so same volume) to stage its new content in.
  static func stagingFile(for target: URL) -> URL {
    target.deletingLastPathComponent().appending(
      path: ".\(target.lastPathComponent).vmlab-new-\(UUID().uuidString)")
  }

  /// Puts `temp` in place of `target` in one `rename(2)`, which replaces an existing `target`
  /// atomically: there is never a moment without either the old file or the new one.
  static func replace(_ target: URL, with temp: URL) throws(VMLabError) {
    guard rename(temp.path, target.path) == 0 else {
      let reason = String(cString: strerror(errno))
      throw VMLabError(
        code: .internal, message: "Cannot replace \(target.path): \(reason)",
        hint: "Check free disk space and permissions under VMLAB_HOME.",
        data: ["path": .string(target.path)])
    }
  }

  static func validate(_ name: String) throws {
    try checkName(name, field: "name")
  }

  static func downloadError(_ url: URL, _ reason: String) -> VMLabError {
    VMLabError(
      code: .engineError, message: "Could not download \(url.absoluteString): \(reason)",
      hint: "Check the network connection and pull again",
      data: ["engine": .string("download"), "raw": .string(reason)])
  }
}
