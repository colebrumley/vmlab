import Foundation
import Testing
import VMLabCore

@Suite struct ImagesIntegrationTests {
  /// R-300 Verify (integration): pulling `debian-13-arm64` succeeds and a second pull is a no-op.
  /// The test home symlinks `~/.vmlab/images`, so the image is pulled once for every later item.
  @Test(.enabled(if: integrationEnabled))
  func debianPullThenNoOp() async throws {
    let shared = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vmlab/images")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    let home = FileManager.default.temporaryDirectory
      .appending(path: "vmlab-test-\(ProcessInfo.processInfo.processIdentifier)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let link = home.appending(path: "images")
    if !FileManager.default.fileExists(atPath: link.path) {
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
    }

    let store = ImageStore(home: home)
    let first = try await store.pull("debian-13-arm64")
    #expect(first.image.files["raw"] == "disk.raw")
    #expect(first.image.files["qcow2"] == "disk.qcow2")
    let raw = store.imageDirectory("debian-13-arm64").appending(path: "disk.raw")
    #expect(FileManager.default.fileExists(atPath: raw.path))

    let second = try await store.pull("debian-13-arm64")
    #expect(!second.changed)
    #expect(second.image == first.image)
  }
}
