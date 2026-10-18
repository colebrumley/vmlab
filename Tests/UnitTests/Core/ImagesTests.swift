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

@Suite struct ImagesTests {
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/images")

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

  @Test func defaultHomeHonoursVMLabHome() {
    #expect(ImageStore.defaultHome(environment: ["VMLAB_HOME": "/tmp/x"]).path == "/tmp/x")
    #expect(ImageStore.defaultHome(environment: [:]).lastPathComponent == ".vmlab")
  }
}
