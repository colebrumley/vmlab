import Foundation
import Testing

@testable import VMLabCore

/// R-604: gzip kernels are stored uncompressed, because `VZLinuxBootLoader` takes only an `Image`.
@Suite struct GzipTests {
  static let gzip = "/usr/bin/gzip"

  /// `data` compressed by the system gzip, keeping `name` in the header when given.
  static func compressed(_ data: Data, name: String? = nil) throws -> Data {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-gz-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: name ?? "payload")
    try data.write(to: file)
    let process = Process()
    process.executableURL = URL(filePath: gzip)
    process.arguments = name == nil ? ["-n", file.path] : [file.path]
    try process.run()
    process.waitUntilExit()
    return try Data(contentsOf: dir.appending(path: file.lastPathComponent + ".gz"))
  }

  static let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 >> 3) })

  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: gzip)))
  func decompressesWithAndWithoutAName() throws {
    for name in [nil, "Image"] {
      let gz = try Self.compressed(Self.payload, name: name)
      #expect(Gzip.isGzip(gz))
      #expect(try Gzip.decompress(gz) == Self.payload)
    }
  }

  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: gzip)))
  func decompressInPlaceRewritesOnlyGzipFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-gz-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let packed = dir.appending(path: "vmlinuz")
    try Self.compressed(Self.payload, name: "Image").write(to: packed)
    try Gzip.decompressInPlace(packed)
    #expect(try Data(contentsOf: packed) == Self.payload)
    let plain = dir.appending(path: "Image")
    try Data("MZ uncompressed".utf8).write(to: plain)
    try Gzip.decompressInPlace(plain)
    #expect(try Data(contentsOf: plain) == Data("MZ uncompressed".utf8))
  }

  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: gzip)))
  func corruptStreamIsInvalidRequest() throws {
    var gz = try Self.compressed(Self.payload)
    gz.replaceSubrange((gz.count - 4)..<gz.count, with: [1, 2, 3, 4])
    #expect {
      try Gzip.decompress(gz)
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    #expect(!Gzip.isGzip(Data("plain".utf8)))
  }
}
