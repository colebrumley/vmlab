import Foundation
import Testing
import VMLabMCP

/// `scripts/release.sh` bakes the release's version into the one `version = "…"` line of
/// `VMLabMCP.swift`; these keep that line where the script looks for it.
@Suite struct VersionTests {
  static let root = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  @Test func sourceHasTheSingleLineReleaseRewrites() throws {
    let source = try String(
      contentsOf: Self.root.appending(path: "Sources/VMLabMCP/VMLabMCP.swift"), encoding: .utf8)
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).filter {
      $0.hasPrefix("  public static let version = \"") && $0.hasSuffix("\"")
    }
    #expect(lines == ["  public static let version = \"\(VMLabMCP.version)\""])
  }

  @Test func releaseScriptRewritesThatLine() throws {
    let script = try String(
      contentsOf: Self.root.appending(path: "scripts/release.sh"), encoding: .utf8)
    #expect(script.contains("Sources/VMLabMCP/VMLabMCP.swift"))
    #expect(script.contains(#"pattern='^\(  public static let version = \)".*"$'"#))
  }

  @Test func versionIsDotted() {
    #expect(VMLabMCP.version.split(separator: ".").count >= 3)
  }
}
