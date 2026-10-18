import Foundation
import Testing

/// True when integration tests should run (`VMLAB_INTEGRATION=1`); they boot real guests.
let integrationEnabled = ProcessInfo.processInfo.environment["VMLAB_INTEGRATION"] == "1"

extension Tag {
  /// Minutes-long tests (TCG emulation); run them only when a Verify line names them.
  @Tag static var slow: Self
}
