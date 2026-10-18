import Foundation
import Testing

@testable import VMLabCore

@Suite struct ImageCacheTests {
  static let big = ImageCatalogue(images: [
    CatalogImage(
      name: "huge-mac", guest: GuestSpec(os: .macos, arch: .arm64), url: "ghcr.io/x/huge:1",
      format: .tart, login: ImageLogin(user: "admin"), approxBytes: 25_000_000_000),
    CatalogImage(
      name: "small", guest: GuestSpec(os: .linux, arch: .arm64), url: "https://x.invalid/s.qcow2",
      format: .qcow2, login: ImageLogin(user: "debian"), approxBytes: 300_000_000),
    CatalogImage(
      name: "unsized", guest: GuestSpec(os: .linux, arch: .arm64), url: "https://x.invalid/u",
      format: .qcow2, login: ImageLogin(user: "debian")),
  ])

  static func home() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "vmlab-cache-\(UUID())")
  }

  /// R-1003 Verify: the confirm gate on pulls over 10 GB, with the size stated.
  @Test func pullsOverTenGBNeedConfirm() throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = ImageStore(home: home, catalogue: Self.big)
    let error = #expect(throws: VMLabError.self) {
      try store.checkPullSize("huge-mac", confirm: false)
    }
    #expect(error?.code == .confirmRequired)
    #expect(error?.data["bytes"] == .number(25_000_000_000))
    #expect(error?.message.contains("about 25 GB") == true, "\(error?.message ?? "")")
    #expect(throws: Never.self) { try store.checkPullSize("huge-mac", confirm: true) }
    #expect(throws: Never.self) { try store.checkPullSize("small", confirm: false) }
    #expect(throws: Never.self) { try store.checkPullSize("unsized", confirm: false) }
    #expect(throws: Never.self) { try store.checkPullSize("not-in-catalogue", confirm: false) }

    // The built-in catalogue gates the macOS image only.
    let builtin = ImageStore(home: home)
    for image in ImageCatalogue.builtin.images {
      let gated = (try? builtin.checkPullSize(image.name, confirm: false)) == nil
      #expect(gated == (image.guest.os == .macos), "\(image.name)")
    }
  }

  @Test func anAlreadyPulledImageNeedsNoConfirm() async throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = ImageStore(home: home, catalogue: Self.big)
    let kernel = home.appending(path: "Image")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("k".utf8).write(to: kernel)
    _ = try await store.registerKernel("huge-mac", kernel: kernel)
    #expect(throws: Never.self) { try store.checkPullSize("huge-mac", confirm: false) }
  }

  /// R-1003 Verify: the reference check. Images a VM names are kept; others, pulled or
  /// registered, go; a directory without image.json (a pull in progress) is left alone.
  @Test func pruneRemovesOnlyUnreferencedImages() async throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = ImageStore(home: home, catalogue: Self.big)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let kernel = home.appending(path: "Image")
    try Data(repeating: 1, count: 8192).write(to: kernel)
    for name in ["used", "unused", "also-unused"] {
      _ = try await store.registerKernel(name, kernel: kernel)
    }
    let partial = store.imageDirectory("pulling")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: partial.appending(path: "disk.qcow2.partial"))

    let records = [
      VMRecord(
        id: "vm-aaaaaa", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [], image: "used"),
      VMRecord(
        id: "vm-bbbbbb", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [], image: "gone-already"),
      VMRecord(
        id: "vm-cccccc", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: []),
    ]
    let referenced = ImageStore.references(records)
    #expect(referenced == ["used", "gone-already"])
    let doomed = store.unreferenced(referenced)
    #expect(doomed.map(\.name) == ["also-unused", "unused"])
    #expect(doomed.allSatisfy { $0.bytes >= 8192 })

    let removed = try await store.prune(referenced: referenced)
    #expect(removed == doomed)
    #expect(store.pulled("used") != nil)
    #expect(store.pulled("unused") == nil && store.pulled("also-unused") == nil)
    #expect(FileManager.default.fileExists(atPath: partial.path))
    #expect(try await store.prune(referenced: referenced).isEmpty)
  }

  @Test func sizesFollowASymlinkedImagesDirectory() throws {
    let root = Self.home()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appending(path: "real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try Data(repeating: 2, count: 10_000).write(to: real.appending(path: "disk.raw"))
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let sizes = ImageStore.sizes(of: link)
    #expect(sizes.logical == 10_000)
    #expect(sizes.allocated >= 10_000)
  }
}
