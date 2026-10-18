import CryptoKit
import Foundation

/// Stand-in executables (fake `ssh`, `scp`, `tart`…) for tests, installed as hard links to one
/// content-addressed copy per script body under `$TMPDIR/vmlab-test-scripts`.
///
/// macOS assesses every newly written executable on its first exec, in one system daemon shared
/// by every process on the host: alone it costs about 0.25 s, with a dozen tests doing it at once
/// over 1.5 s each, which is what made tests with a 5 or 10 s deadline flaky. The verdict sticks
/// to the file, so a link to a body that has run before starts at once. A body must therefore
/// not embed per-run paths: take them from `$0` (`$(dirname "$0")`) or the arguments instead.
///
/// The cached file is read-only, so a test that writes through its link fails loudly instead of
/// changing the script for every other test; replacing the link (an atomic write) is fine.
enum TestScripts {
  static let cache = FileManager.default.temporaryDirectory.appending(path: "vmlab-test-scripts")

  /// Installs `body` as an executable at `url`, replacing what is there.
  static func install(_ body: String, at url: URL) throws {
    let data = Data(body.utf8)
    let cached = try cachedFile(for: data)
    try? FileManager.default.removeItem(at: url)
    if link(cached.path, url.path) != 0 {
      // Another volume: an ordinary copy, assessed on its first run like any new file.
      try data.write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
  }

  private static func cachedFile(for data: Data) throws -> URL {
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let url = cache.appending(path: name)
    if (try? Data(contentsOf: url)) == data { return url }
    // Written aside, then moved into place, so a parallel test never runs a half-written file.
    let temp = cache.appending(path: "\(name).\(UUID().uuidString)")
    try data.write(to: temp)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temp.path)
    guard rename(temp.path, url.path) == 0 else {
      let code = errno
      try? FileManager.default.removeItem(at: temp)
      throw CocoaError(.fileWriteUnknown, userInfo: ["errno": code])
    }
    return url
  }
}
