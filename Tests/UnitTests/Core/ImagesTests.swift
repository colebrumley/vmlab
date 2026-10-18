import Foundation
import Synchronization
import Testing
import VMLabCore

/// Serves URLs from files on disk and counts what it was asked for.
final class FileDownloader: ImageDownloading {
  let files: [String: URL]
  let downloads = Mutex(0)

  init(files: [String: URL]) { self.files = files }

  func data(from url: URL) async throws -> Data {
    guard let file = files[url.absoluteString] else { throw URLError(.cannotConnectToHost) }
    return try Data(contentsOf: file)
  }

  func download(from url: URL, to destination: URL) async throws {
    guard let file = files[url.absoluteString] else { throw URLError(.cannotConnectToHost) }
    downloads.withLock { $0 += 1 }
    try FileManager.default.copyItem(at: file, to: destination)
  }
}

/// Stands in for `qemu-img convert`: copies the input to the output and records the call.
final class ConvertRunner: CommandRunning {
  let calls = Mutex<[[String]]>([])

  func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
    calls.withLock { $0.append([URL(filePath: executable).lastPathComponent] + arguments) }
    guard arguments.first == "convert", arguments.count >= 2 else {
      return CommandOutput(status: 1, output: "unexpected")
    }
    let input = URL(filePath: arguments[arguments.count - 2])
    let output = URL(filePath: arguments[arguments.count - 1])
    do { try FileManager.default.copyItem(at: input, to: output) } catch { return nil }
    return CommandOutput(status: 0, output: "")
  }
}

/// Stands in for `tart`: succeeds and records the call.
final class TartRunner: CommandRunning {
  let calls = Mutex<[[String]]>([])

  func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
    calls.withLock { $0.append([URL(filePath: executable).lastPathComponent] + arguments) }
    return CommandOutput(status: 0, output: "")
  }
}

@Suite struct ImagesTests {
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/images")

  /// Writes `images/<directory>/image.json` naming `files`, for the path-policy tests.
  static func plant(_ store: ImageStore, directory: URL, files: [String: String]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = PulledImage(
      name: directory.lastPathComponent, guest: GuestSpec(os: .linux, arch: .arm64),
      source: "x", format: .qcow2, checksum: nil, files: files,
      login: ImageLogin(user: "debian"), pulledAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: directory.appending(path: "image.json"))
  }

  /// CR-4: an image name with `/` or `..` is never looked up outside images/, and a pulled
  /// record whose files escape its directory (by path or by symlink) is not a pulled image.
  @Test func pulledRefusesNamesAndFilesOutsideTheImageDirectory() throws {
    let (home, bin) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let store = ImageStore(home: home, catalogue: try Self.catalogue(), searchPaths: [bin.path])
    let outside = home.appending(path: "outside")
    try Self.plant(store, directory: outside, files: ["raw": "disk.raw"])
    #expect(store.pulled("../outside") == nil)
    #expect(store.pulled("a/b") == nil)

    for files in [["raw": "/etc/hosts"], ["raw": "../../outside/disk.raw"], ["raw": ""]] {
      try Self.plant(store, directory: store.imageDirectory("bad"), files: files)
      #expect(store.pulled("bad") == nil, "files \(files)")
    }
    try Self.plant(store, directory: store.imageDirectory("bad"), files: ["raw": "disk.raw"])
    try FileManager.default.createSymbolicLink(
      atPath: store.imageDirectory("bad").appending(path: "disk.raw").path,
      withDestinationPath: "/etc/hosts")
    #expect(store.pulled("bad") == nil)

    try Self.plant(
      store, directory: store.imageDirectory("good"),
      files: ["raw": "disk.raw", "kernel": "kernel/vmlinuz"])
    #expect(store.pulled("good")?.files["kernel"] == "kernel/vmlinuz")
  }

  @Test func imageNamesAreCheckedWhereverTheyAreAccepted() throws {
    for name in ["../../tmp/x", "a/b", "..", "."] {
      let error = #expect(throws: VMLabError.self) {
        try Requirements(guest: GuestSpec(os: .linux, arch: .arm64), image: name)
      }
      #expect(error?.data["field"] == .string("image"))
    }
    _ = try Requirements(guest: GuestSpec(os: .linux, arch: .arm64), image: "debian-13-arm64")
  }

  static func catalogue() throws -> ImageCatalogue {
    try ImageCatalogue.decode(Data(contentsOf: fixtures.appending(path: "catalogue.json")))
  }

  /// A fresh home with a fake `qemu-img` on the search path.
  static func sandbox() throws -> (home: URL, bin: URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "vmlab-images-\(UUID())")
    let bin = root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let tool = bin.appending(path: "qemu-img")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    return (root.appending(path: "home"), bin)
  }

  static func downloader(sums: String = "SHA512SUMS") -> FileDownloader {
    FileDownloader(files: [
      "https://example.invalid/images/tiny.qcow2": fixtures.appending(path: "tiny.qcow2"),
      "https://example.invalid/images/SHA512SUMS": fixtures.appending(path: sums),
    ])
  }

  @Test func fixtureCatalogueDecodes() throws {
    let catalogue = try Self.catalogue()
    #expect(catalogue.images.map(\.name) == ["tiny-arm64", "tiny-mac"])
    let tiny = try #require(catalogue.image(named: "tiny-arm64"))
    #expect(tiny.guest == GuestSpec(os: .linux, arch: .arm64))
    #expect(tiny.format == .qcow2)
    #expect(tiny.convertToRaw)
    #expect(tiny.checksumAlgorithm == .sha512)
    #expect(tiny.fileName == "tiny.qcow2")
    #expect(tiny.login == ImageLogin(user: "debian"))
    #expect(catalogue.image(named: "tiny-mac")?.login.password == "admin")
  }

  @Test func builtinCatalogueIsAppendixH() {
    let catalogue = ImageCatalogue.builtin
    #expect(
      catalogue.images.map(\.name) == [
        "debian-13-arm64", "debian-13-amd64", "ubuntu-24.04-arm64", "ubuntu-24.04-amd64",
        "macos-base",
      ])
    let debian = catalogue.image(named: "debian-13-arm64")
    #expect(debian?.fileName == "debian-13-genericcloud-arm64.qcow2")
    #expect(debian?.convertToRaw == true)
    #expect(catalogue.image(named: "debian-13-amd64")?.guest.arch == .x86_64)
    #expect(catalogue.image(named: "ubuntu-24.04-arm64")?.checksumAlgorithm == .sha256)
    #expect(catalogue.image(named: "macos-base")?.format == .tart)
    for image in catalogue.images where image.format != .tart {
      #expect(image.checksumURL != nil && image.checksumAlgorithm != nil, "\(image.name)")
    }
  }

  /// R-1000: the Ubuntu and amd64 entries carry their checksum URLs, and every amd64 image is
  /// one only qemu-tcg runs (so it is never converted to raw for VZ).
  @Test func ubuntuAndAmd64Catalogue() throws {
    let catalogue = ImageCatalogue.builtin
    let ubuntu = try #require(catalogue.image(named: "ubuntu-24.04-arm64"))
    #expect(
      ubuntu.url == "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img")
    #expect(
      ubuntu.checksumURL?.absoluteString
        == "https://cloud-images.ubuntu.com/noble/current/SHA256SUMS")
    #expect(ubuntu.fileName == "noble-server-cloudimg-arm64.img")
    #expect(ubuntu.format == .qcow2 && ubuntu.convertToRaw)
    #expect(ubuntu.login == ImageLogin(user: "ubuntu"))
    let ubuntuAmd64 = try #require(catalogue.image(named: "ubuntu-24.04-amd64"))
    #expect(ubuntuAmd64.fileName == "noble-server-cloudimg-amd64.img")
    #expect(ubuntuAmd64.checksumAlgorithm == .sha256)
    let debianAmd64 = try #require(catalogue.image(named: "debian-13-amd64"))
    #expect(debianAmd64.fileName == "debian-13-genericcloud-amd64.qcow2")
    #expect(debianAmd64.checksumURL?.lastPathComponent == "SHA512SUMS")

    let amd64 = catalogue.images.filter { $0.guest.arch == .x86_64 }
    #expect(Set(amd64.map(\.name)) == ["debian-13-amd64", "ubuntu-24.04-amd64"])
    for image in amd64 {
      #expect(!image.convertToRaw, "\(image.name)")
      let profiles = Profile.allCases.filter { Capabilities.supports(image.guest, on: $0) }
      #expect(profiles == [.qemuTCG], "\(image.name)")
      let plan = try ProfileSelector.select(
        try Requirements(guest: image.guest, image: image.name), host: SelectorTests.devHost(),
        running: .empty
      ).get()
      #expect(plan.profile == .qemuTCG, "\(image.name)")
    }
  }

  @Test func guestOfAnImageIsItsRecordsElseTheCatalogues() throws {
    let (home, bin) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let store = ImageStore(home: home, catalogue: try Self.catalogue(), searchPaths: [bin.path])
    #expect(store.guest(of: "tiny-arm64") == GuestSpec(os: .linux, arch: .arm64))
    #expect(store.guest(of: "tiny-mac")?.os == .macos)
    #expect(store.guest(of: "nothing") == nil)
  }

  @Test func parsesChecksumLists() throws {
    let sha512 = ChecksumList.parse(
      try String(contentsOf: Self.fixtures.appending(path: "SHA512SUMS"), encoding: .utf8))
    #expect(sha512.count == 2)
    #expect(sha512["tiny.qcow2"]?.count == 128)
    let sha256 = ChecksumList.parse(
      try String(contentsOf: Self.fixtures.appending(path: "SHA256SUMS"), encoding: .utf8))
    #expect(sha256["tiny.qcow2"]?.count == 64)
    #expect(ChecksumList.parse("not a checksum line\n\n").isEmpty)
  }

  @Test func digestsMatchTheFixtureSums() throws {
    let disk = Self.fixtures.appending(path: "tiny.qcow2")
    let sha512 = ChecksumList.parse(
      try String(contentsOf: Self.fixtures.appending(path: "SHA512SUMS"), encoding: .utf8))
    let sha256 = ChecksumList.parse(
      try String(contentsOf: Self.fixtures.appending(path: "SHA256SUMS"), encoding: .utf8))
    #expect(try ChecksumAlgorithm.sha512.hexDigest(ofFileAt: disk) == sha512["tiny.qcow2"])
    #expect(try ChecksumAlgorithm.sha256.hexDigest(ofFileAt: disk) == sha256["tiny.qcow2"])
  }

  @Test func pullVerifiesConvertsAndRecords() async throws {
    let (home, bin) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let downloader = Self.downloader()
    let runner = ConvertRunner()
    let store = ImageStore(
      home: home, catalogue: try Self.catalogue(), downloader: downloader, runner: runner,
      searchPaths: [bin.path])

    let first = try await store.pull("tiny-arm64")
    #expect(first.changed)
    #expect(first.image.files == ["qcow2": "disk.qcow2", "raw": "disk.raw"])
    #expect(first.image.checksum?.algorithm == .sha512)
    let folder = store.imageDirectory("tiny-arm64")
    for file in ["image.json", "disk.qcow2", "disk.raw", "checksums"] {
      #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path), "\(file)")
    }
    #expect(
      runner.calls.withLock { $0.first?.prefix(5) } == ["qemu-img", "convert", "-f", "qcow2", "-O"])
    #expect(store.pulled("tiny-arm64") == first.image)

    let second = try await store.pull("tiny-arm64")
    #expect(!second.changed)
    #expect(downloader.downloads.withLock { $0 } == 1)
    #expect(runner.calls.withLock { $0.count } == 1)

    let listing = store.list()
    #expect(listing.map(\.name) == ["tiny-arm64", "tiny-mac"])
    #expect(listing[0].pulled != nil && listing[1].pulled == nil)

    #expect(try await store.remove("tiny-arm64"))
    #expect(store.pulled("tiny-arm64") == nil)
    #expect(try await !store.remove("tiny-arm64"))
  }

  @Test func checksumMismatchIsRefusedAndLeavesNothing() async throws {
    let (home, bin) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let bad = home.deletingLastPathComponent().appending(path: "BADSUMS")
    try Data("\(String(repeating: "ab", count: 64))  tiny.qcow2\n".utf8).write(to: bad)
    let downloader = FileDownloader(files: [
      "https://example.invalid/images/tiny.qcow2": Self.fixtures.appending(path: "tiny.qcow2"),
      "https://example.invalid/images/SHA512SUMS": bad,
    ])
    let store = ImageStore(
      home: home, catalogue: try Self.catalogue(), downloader: downloader, runner: ConvertRunner(),
      searchPaths: [bin.path])
    let error = await #expect(throws: VMLabError.self) { try await store.pull("tiny-arm64") }
    #expect(error?.code == .engineError)
    #expect(error?.data["engine"] == .string("download"))
    let folder = store.imageDirectory("tiny-arm64")
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "disk.qcow2").path))
    #expect(store.pulled("tiny-arm64") == nil)
  }

  @Test func unknownImageNamesTheAvailableOnes() async throws {
    let (home, bin) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let store = ImageStore(
      home: home, catalogue: try Self.catalogue(), downloader: Self.downloader(),
      runner: ConvertRunner(), searchPaths: [bin.path])
    let error = await #expect(throws: VMLabError.self) { try await store.pull("nope") }
    #expect(error?.code == .imageNotFound)
    #expect(error?.data["available"] == .array([.string("tiny-arm64"), .string("tiny-mac")]))
    await #expect(throws: VMLabError.self) { try await store.remove("../escape") }
  }

  @Test func missingQEMUImgIsHostMissingTool() async throws {
    let (home, _) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let store = ImageStore(
      home: home, catalogue: try Self.catalogue(), downloader: Self.downloader(),
      runner: ConvertRunner(), searchPaths: [])
    let error = await #expect(throws: VMLabError.self) { try await store.pull("tiny-arm64") }
    #expect(error?.code == .hostMissingTool)
    #expect(error?.data["tool"] == .string("qemu-img"))
    let tart = await #expect(throws: VMLabError.self) { try await store.pull("tiny-mac") }
    #expect(tart?.data["tool"] == .string("tart"))
  }

  /// R-605: `images pull` of a Tart image runs `tart pull <ref>` and records the ref as the Tart
  /// VM that `tart clone` takes; a second pull is a no-op.
  @Test func tartPullRecordsTheTartVMName() async throws {
    let (home, bin) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let tart = bin.appending(path: "tart")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tart)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tart.path)
    let runner = TartRunner()
    let store = ImageStore(
      home: home, catalogue: try Self.catalogue(), downloader: Self.downloader(), runner: runner,
      searchPaths: [bin.path])
    let first = try await store.pull("tiny-mac")
    #expect(first.changed)
    #expect(first.image.tartVM == "ghcr.io/example/tiny:latest")
    #expect(first.image.format == .tart)
    #expect(store.pulled("tiny-mac")?.tartVM == "ghcr.io/example/tiny:latest")
    #expect(try await store.pull("tiny-mac").changed == false)
    #expect(runner.calls.withLock { $0 } == [["tart", "pull", "ghcr.io/example/tiny:latest"]])
  }

  /// CX-2: an image a VM's disk reads (its `image`, or a backing chain into its directory) is
  /// neither removed nor replaced by a pull of a changed upstream file; an unused one is.
  @Test func imagesInUseAreNotRemovedOrReplaced() async throws {
    let (home, bin) = try Self.sandbox()
    let root = home.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: root) }
    let changed = root.appending(path: "tiny-v2.qcow2")
    var bytes = try Data(contentsOf: Self.fixtures.appending(path: "tiny.qcow2"))
    bytes.append(contentsOf: [1, 2, 3])
    try bytes.write(to: changed)
    let sums = root.appending(path: "SUMS-v2")
    try Data(
      "\(try ChecksumAlgorithm.sha512.hexDigest(ofFileAt: changed))  tiny.qcow2\n".utf8
    ).write(to: sums)
    let images = ImageStore(
      home: home, catalogue: try Self.catalogue(), downloader: Self.downloader(),
      runner: ConvertRunner(), searchPaths: [bin.path])
    _ = try await images.pull("tiny-arm64")
    let disk = images.imageDirectory("tiny-arm64").appending(path: "disk.qcow2")
    let original = try Data(contentsOf: disk)

    let vms = Store(home: home)
    let user = try vms.create(
      VMRecord(
        id: "vm-aaaaaa", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [], image: "tiny-arm64"))
    let removal = await #expect(throws: VMLabError.self) { try await images.remove("tiny-arm64") }
    #expect(removal?.code == .invalidRequest)
    #expect(removal?.data["vms"] == .array([.string(user.id)]))
    #expect(images.pulled("tiny-arm64") != nil)

    let repull = ImageStore(
      home: home, catalogue: try Self.catalogue(),
      downloader: FileDownloader(files: [
        "https://example.invalid/images/tiny.qcow2": changed,
        "https://example.invalid/images/SHA512SUMS": sums,
      ]), runner: ConvertRunner(), searchPaths: [bin.path])
    let replaced = await #expect(throws: VMLabError.self) { try await repull.pull("tiny-arm64") }
    #expect(replaced?.code == .invalidRequest)
    #expect(try Data(contentsOf: disk) == original)

    // A clone's backing chain into the image directory counts too.
    try vms.remove(id: user.id)
    var clone = VMRecord(
      id: "vm-bbbbbb", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [])
    clone.backingChain = [disk.path]
    let cloned = try vms.create(clone)
    await #expect(throws: VMLabError.self) { try await images.remove("tiny-arm64") }
    #expect(try await images.prune(referenced: []).isEmpty)

    try vms.remove(id: cloned.id)
    #expect(try await repull.pull("tiny-arm64").changed)
    #expect(try Data(contentsOf: disk) == bytes)
    #expect(try await images.remove("tiny-arm64"))
  }

  /// Takes its time over each download, so two pulls overlap.
  final class SlowDownloader: ImageDownloading {
    let inner: FileDownloader
    init(_ inner: FileDownloader) { self.inner = inner }
    func data(from url: URL) async throws -> Data { try await inner.data(from: url) }
    func download(from url: URL, to destination: URL) async throws {
      try await Task.sleep(for: .milliseconds(200))
      try await inner.download(from: url, to: destination)
    }
  }

  /// CX-11: two pulls of one image at once share one download (one `.partial`), both succeed.
  @Test func concurrentPullsOfOneImageShareOneDownload() async throws {
    let (home, bin) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let downloader = Self.downloader()
    let store = ImageStore(
      home: home, catalogue: try Self.catalogue(), downloader: SlowDownloader(downloader),
      runner: ConvertRunner(), searchPaths: [bin.path])
    async let first = store.pull("tiny-arm64")
    async let second = store.pull("tiny-arm64")
    let results = try await [first, second]
    #expect(results[0].image == results[1].image)
    #expect(downloader.downloads.withLock { $0 } == 1)
    #expect(store.pulled("tiny-arm64") != nil)
  }

  @Test func defaultHomeHonoursVMLabHome() {
    #expect(ImageStore.defaultHome(environment: ["VMLAB_HOME": "/tmp/x"]).path == "/tmp/x")
    #expect(ImageStore.defaultHome(environment: [:]).lastPathComponent == ".vmlab")
  }
}
