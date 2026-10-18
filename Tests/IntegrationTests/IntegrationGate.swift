import Foundation

/// True when integration tests should run (`VMLAB_INTEGRATION=1`); they boot real guests.
let integrationEnabled = ProcessInfo.processInfo.environment["VMLAB_INTEGRATION"] == "1"
