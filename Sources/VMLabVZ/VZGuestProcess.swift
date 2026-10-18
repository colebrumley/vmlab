import Foundation
import VMLabCore

extension VMLabVZ {
  /// Recognises a `vmlab-vz run <vm>` runner as a guest for the host-wide memory count
  /// (`HostMemoryGuard`), with the memory and boot of the `vz-config.json` it was started from.
  public static let guestProcessRecognizer = GuestProcessRecognizer(
    engine: "vz",
    matchesExecutable: { URL(filePath: $0).lastPathComponent == "vmlab-vz" },
    recognize: { process in
      let arguments = process.arguments
      guard arguments.count >= 2, arguments[0] == "run" else { return nil }
      let paths = VZRunnerPaths(vmDirectory: URL(filePath: arguments[1]))
      guard let config = try? VZRunnerConfig.read(from: paths.config) else {
        // A runner whose config is gone still holds memory: count the Linux default.
        return HostGuestProcess(
          pid: process.pid, engine: "vz", memoryGB: 4, directory: paths.vmDirectory.path)
      }
      let macOS = if case .macOS = config.boot { true } else { false }
      return HostGuestProcess(
        pid: process.pid, engine: "vz", memoryGB: Double(config.memoryBytes) / 1_073_741_824,
        directory: paths.vmDirectory.path, os: macOS ? .macos : .linux)
    })
}
