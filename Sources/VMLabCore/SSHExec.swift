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

  /// Runs `request` (R-401). Output past `ExecOutput.inlineLimit` is cut to its head and tail and
  /// the whole is kept at `<vm>/exec/<job>.log`. At the deadline the local `ssh` is ended and a
  /// second connection kills the command's remote process group; the refusal is `timeout` with
  /// the partial output in `data`.
  public func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
    let job = Self.newJobID()
    let files = try ExecFiles(directory: execDirectory, job: job)
    defer { files.removeScratch() }
    let remote = RemoteShell.foreground(request, job: job, loginUser: target.user)
    let started = ContinuousClock.now
    let outcome = try await HostProcess.run(
      ssh, target.arguments(remote: remote), stdin: request.stdin,
      stdout: files.stdout, stderr: files.stderr, timeout: request.timeout)
    let durationMs = Int((ContinuousClock.now - started) / .milliseconds(1))
    files.close()
    if outcome.timedOut {
      // Not under the caller's task: a cancelled call still kills what it started.
      let (ssh, target) = (ssh, target)
      await Task.detached {
        _ = try? await HostProcess.run(
          ssh,
          target.arguments(
            remote: RemoteShell.kill(job: job, user: request.user, loginUser: target.user),
            connectTimeoutSeconds: 5),
          timeout: .seconds(15))
      }.value
    }
    let output = ExecOutput.collect(
      stdout: files.stdoutURL, stderr: files.stderrURL,
      log: execDirectory.appending(path: "\(job).log"))
    if outcome.timedOut {
      throw ExecTimeout.error(
        vm: target.vm, timeout: request.timeout, output: output, durationMs: durationMs)
    }
    if outcome.status == 255, Self.isSSHFailure(output.stderr) {
      throw Self.unreachable(target, output.stderr)
    }
    return ExecResult(
      exitCode: outcome.status, stdout: output.stdout, stderr: output.stderr,
      durationMs: durationMs, truncated: output.truncated, logPath: output.logPath)
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

  /// Whether `ssh` failed before the remote command could start (no session was set up), so the
  /// command may safely go to another channel (R-403).
  static func isConnectFailure(_ stderr: String) -> Bool {
    let markers = [
      "ssh: connect to host", "Permission denied (", "Host key verification failed",
      "kex_exchange_identification", "Connection refused", "Connection timed out",
      "REMOTE HOST IDENTIFICATION HAS CHANGED", "Could not resolve hostname",
    ]
    if stderr.contains("closed by remote host") { return false }
    return markers.contains { stderr.contains($0) }
      || (stderr.contains("Connection closed by") && !stderr.contains("Broken pipe"))
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
        ExecFallback.connectedKey: .bool(!isConnectFailure(stderr)),
      ])
  }
}

/// The scratch files of one command's output under `<vm>/exec/`.
public struct ExecFiles {
  public let stdoutURL: URL
  public let stderrURL: URL
  public let stdout: FileHandle
  public let stderr: FileHandle

  public init(directory: URL, job: String) throws(VMLabError) {
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

  public func close() {
    try? stdout.close()
    try? stderr.close()
  }

  public func removeScratch() {
    close()
    try? FileManager.default.removeItem(at: stdoutURL)
    try? FileManager.default.removeItem(at: stderrURL)
  }
}

/// Output kept inline (Appendix G): up to 64 KB per stream as is; past that the first 16 KB and
/// the last 48 KB around a marker line saying how much was left out.
public enum ExecOutput {
  public static let inlineLimit = 64 * 1024
  public static let headBytes = 16 * 1024
  public static let tailBytes = 48 * 1024

  public struct Collected: Sendable, Hashable {
    public var stdout: String
    public var stderr: String
    public var truncated: Bool
    public var logPath: String?
  }

  /// Reads both scratch files; when either is over the limit, the whole output moves to `log`
  /// (stdout, then stderr after a `==> stderr <==` line when it was cut too).
  public static func collect(stdout: URL, stderr: URL, log: URL) -> Collected {
    let out = excerpt(of: stdout)
    let err = excerpt(of: stderr)
    guard out.cut || err.cut else {
      return Collected(stdout: out.text, stderr: err.text, truncated: false, logPath: nil)
    }
    let files = FileManager.default
    try? files.removeItem(at: log)
    if out.cut {
      try? files.moveItem(at: stdout, to: log)
    } else {
      files.createFile(atPath: log.path, contents: nil)
    }
    if err.cut, let handle = try? FileHandle(forWritingTo: log),
      let source = try? FileHandle(forReadingFrom: stderr)
    {
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(((out.cut ? "\n" : "") + "==> stderr <==\n").utf8))
      while let chunk = try? source.read(upToCount: 1 << 20), !chunk.isEmpty {
        try? handle.write(contentsOf: chunk)
      }
      try? handle.close()
      try? source.close()
    }
    return Collected(stdout: out.text, stderr: err.text, truncated: true, logPath: log.path)
  }

  /// The file's text, or its head and tail around a marker when it is over the limit.
  static func excerpt(of url: URL) -> (text: String, cut: Bool) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", false) }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: 0)
    guard size > UInt64(inlineLimit) else {
      return (String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self), false)
    }
    let head = (try? handle.read(upToCount: headBytes)) ?? Data()
    try? handle.seek(toOffset: size - UInt64(tailBytes))
    let tail = (try? handle.readToEnd()) ?? Data()
    let omitted = size - UInt64(headBytes) - UInt64(tailBytes)
    let text =
      String(decoding: head, as: UTF8.self) + "\n[... \(omitted) bytes omitted; see logPath ...]\n"
      + String(decoding: tail, as: UTF8.self)
    return (text, true)
  }
}
