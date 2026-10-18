import Foundation

extension ExecChannel where Self == SSHExecChannel {
  /// Commands over the system `ssh` with the VM's key (R-400).
  public static func ssh(_ target: SSHTarget) -> SSHExecChannel { SSHExecChannel(target: target) }
}

/// Runs commands in the guest with the system `ssh` (`SSHTarget.arguments`). Output is written to
/// files under `<vm>/exec/` while the command runs, so a large output never sits in memory.
public struct SSHExecChannel: ExecChannel {
  public var target: SSHTarget
  public var ssh: String

  public init(target: SSHTarget, ssh: String = SSHKeys.ssh) {
    self.target = target
    self.ssh = ssh
  }

  public var execDirectory: URL { target.vmDirectory.appending(path: "exec") }

  public func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
    let job = Self.newJobID()
    let files = try ExecFiles(directory: execDirectory, job: job)
    defer { files.removeScratch() }
    let started = ContinuousClock.now
    let outcome = try await HostProcess.run(
      ssh, target.arguments(remote: request.command), stdin: request.stdin,
      stdout: files.stdout, stderr: files.stderr, timeout: request.timeout)
    let duration = ContinuousClock.now - started
    files.close()
    let stdout = files.read(files.stdoutURL)
    let stderr = files.read(files.stderrURL)
    if outcome.timedOut {
      throw VMLabError(
        code: .timeout,
        message: "The command did not finish within \(request.timeout.components.seconds) s",
        hint: "Raise timeoutSeconds, or run it with background: true and poll vm_job.",
        data: [
          "vm": .string(target.vm),
          "timeoutSeconds": .number(Double(request.timeout.components.seconds)),
          "stdout": .string(String(decoding: stdout, as: UTF8.self)),
          "stderr": .string(String(decoding: stderr, as: UTF8.self)),
        ])
    }
    let errorText = String(decoding: stderr, as: UTF8.self)
    if outcome.status == 255, Self.isSSHFailure(errorText) {
      throw Self.unreachable(target, errorText)
    }
    return ExecResult(
      exitCode: outcome.status, stdout: String(decoding: stdout, as: UTF8.self), stderr: errorText,
      durationMs: Int(duration.components.seconds * 1000)
        + Int(duration.components.attoseconds / 1_000_000_000_000_000))
  }

  // MARK: Helpers

  /// A short unique id: `j-` and twelve hex digits.
  public static func newJobID() -> String {
    "j-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
  }

  /// Whether exit status 255 came from `ssh` itself rather than the remote command.
  static func isSSHFailure(_ stderr: String) -> Bool {
    let markers = [
      "ssh: ", "Permission denied (", "Host key verification failed", "kex_exchange_identification",
      "Connection closed by", "Connection reset by", "Connection timed out", "Connection refused",
      "REMOTE HOST IDENTIFICATION HAS CHANGED", "Could not resolve hostname", "Broken pipe",
    ]
    return markers.contains { stderr.contains($0) }
  }

  static func unreachable(_ target: SSHTarget, _ stderr: String) -> VMLabError {
    let last =
      stderr.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
      ?? ""
    return VMLabError(
      code: .guestUnreachable,
      message:
        "SSH to \(target.vm) at \(target.endpoint.host):\(target.endpoint.port) failed: \(last)",
      hint: "The guest may still be booting; wait and retry, or read vm_serial to see where it is.",
      data: [
        "vm": .string(target.vm), "tried": .array([.string("ssh")]), "error": .string(last),
      ])
  }
}

/// The scratch files of one command's output under `<vm>/exec/`.
struct ExecFiles {
  let stdoutURL: URL
  let stderrURL: URL
  let stdout: FileHandle
  let stderr: FileHandle

  init(directory: URL, job: String) throws(VMLabError) {
    stdoutURL = directory.appending(path: "\(job).stdout")
    stderrURL = directory.appending(path: "\(job).stderr")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for url in [stdoutURL, stderrURL] {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
          throw CocoaError(.fileWriteUnknown)
        }
      }
      stdout = try FileHandle(forWritingTo: stdoutURL)
      stderr = try FileHandle(forWritingTo: stderrURL)
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot create the exec output files in \(directory.path)",
        hint: "Check that the VM directory is writable.",
        data: ["id": .string(job), "error": .string("\(error)")])
    }
  }

  func close() {
    try? stdout.close()
    try? stderr.close()
  }

  func read(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

  func removeScratch() {
    close()
    try? FileManager.default.removeItem(at: stdoutURL)
    try? FileManager.default.removeItem(at: stderrURL)
  }
}
