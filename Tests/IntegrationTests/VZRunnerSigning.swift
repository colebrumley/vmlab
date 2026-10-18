import Foundation
import Testing
import VMLabCore

/// Signs `.build/debug/vmlab-vz` with the virtualization entitlement once per test process.
///
/// `swift test` relinks the runner without its entitlement. Every VZ integration suite needs it
/// signed, and suites run in parallel: two `codesign --force` runs on one file at the same moment
/// (or a copy taken while one rewrites it) leave a broken binary. A `static let` initialiser runs
/// exactly once, and the other callers wait for it, so the file is rewritten at most once.
enum VZRunnerSigning {
  /// `nil` when the runner was already signed or signing succeeded; else what went wrong.
  private static let failure: String? = signIfNeeded()

  /// Ensures the runner carries the entitlement; records an issue if signing failed.
  static func ensureSigned() {
    if let failure { Issue.record(Comment(rawValue: failure)) }
  }

  private static func codesign(_ arguments: [String]) -> CommandOutput? {
    ProcessRunner().run("/usr/bin/codesign", arguments)
  }

  private static func signIfNeeded() -> String? {
    let runner = VZRunnerIntegrationTests.runner
    if let shown = codesign(["-d", "--entitlements", "-", runner]), shown.status == 0,
      CodeSignature.hasVirtualizationEntitlement(codesignOutput: shown.output)
    {
      return nil
    }
    let entitlements = VZRunnerIntegrationTests.root
      .appending(path: "Sources/vmlab-vz/vmlab-vz.entitlements").path
    guard
      let signed = codesign(["--force", "--sign", "-", "--entitlements", entitlements, runner]),
      signed.status == 0
    else { return "codesign of \(runner) failed" }
    return nil
  }
}
