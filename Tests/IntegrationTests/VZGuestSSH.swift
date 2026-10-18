import Foundation

/// `ssh debian@<ip>` into a VZ test guest with its own key, killed after a hard limit so a stalled
/// session (a guest busy installing packages) cannot hang a test.
enum VZGuestSSH {
  /// The exit status and combined output; nil when ssh could not run or hit `limit`.
  static func run(
    key: URL, host: String, command: String, user: String = "debian", limit: Duration
  ) async -> (status: Int32, output: String)? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ssh")
    process.arguments = [
      "-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
      "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
      "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "\(user)@\(host)", command,
    ]
    let output = FileManager.default.temporaryDirectory
      .appending(path: "vmlab-ssh-\(UUID().uuidString).out")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: output) }
    guard let handle = try? FileHandle(forWritingTo: output) else { return nil }
    defer { try? handle.close() }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle
    guard (try? process.run()) != nil else { return nil }
    let deadline = ContinuousClock.now + limit
    while process.isRunning, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(200))
    }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      return nil
    }
    let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    return (process.terminationStatus, text)
  }

  /// Runs `command` every few seconds until it exits 0 or `within` passes; the last result.
  static func poll(
    key: URL, host: String, command: String, within: Duration
  ) async -> (status: Int32, output: String)? {
    let deadline = ContinuousClock.now + within
    var last: (status: Int32, output: String)? = nil
    while ContinuousClock.now < deadline {
      last = await run(key: key, host: host, command: command, limit: .seconds(30))
      if last?.status == 0 { return last }
      try? await Task.sleep(for: .seconds(3))
    }
    return last
  }
}
