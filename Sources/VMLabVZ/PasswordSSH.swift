import Foundation
import VMLabCore

/// SSH to a fresh macOS guest with the image's password (Appendix H: `admin`/`admin`), before
/// the VM's own key is installed (R-606). The system `ssh` reads the password from an askpass
/// script (`SSH_ASKPASS_REQUIRE=force`) that prints `$VMLAB_SSH_PASSWORD`, so the password is
/// never an argument and no shell sees model input.
public struct PasswordSSH: Sendable {
  public var user: String
  public var host: String
  public var password: String
  /// Where the askpass script is written (the VM directory).
  public var scratch: URL
  public var ssh: String = "/usr/bin/ssh"

  public init(user: String, host: String, password: String, scratch: URL) {
    self.user = user
    self.host = host
    self.password = password
    self.scratch = scratch
  }

  static let askpassScript = "#!/bin/sh\nprintf '%s\\n' \"$VMLAB_SSH_PASSWORD\"\n"

  public var askpass: URL { scratch.appending(path: "askpass.sh") }

  /// The `ssh` arguments: password authentication only, no host key pinning (the images are
  /// disposable and the host key is new on every clone), then `command`.
  public func arguments(_ command: String) -> [String] {
    [
      "-o", "PreferredAuthentications=password,keyboard-interactive",
      "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
      "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
      "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "\(user)@\(host)", command,
    ]
  }

  /// Runs `command` in the guest with `input` on its stdin; nil when `ssh` cannot launch or does
  /// not finish within `timeout` (it is then killed).
  public func run(_ command: String, input: Data = Data(), timeout: Duration = .seconds(60))
    async -> CommandOutput?
  {
    do {
      try Data(Self.askpassScript.utf8).write(to: askpass, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
    } catch {
      return nil
    }
    var environment = ProcessInfo.processInfo.environment
    environment["SSH_ASKPASS"] = askpass.path
    environment["SSH_ASKPASS_REQUIRE"] = "force"
    environment["VMLAB_SSH_PASSWORD"] = password
    environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
    return await HostCommand.run(
      ssh, arguments(command), environment: environment, input: input, timeout: timeout)
  }
}

/// One host subprocess with an environment, stdin and a deadline, waited for on a thread of its
/// own so it never blocks the cooperative pool.
enum HostCommand {
  static func run(
    _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
    input: Data = Data(), timeout: Duration
  ) async -> CommandOutput? {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        continuation.resume(
          returning: runBlocking(
            executable, arguments, environment: environment, input: input, timeout: timeout))
      }
    }
  }

  static func runBlocking(
    _ executable: String, _ arguments: [String], environment: [String: String]?, input: Data,
    timeout: Duration
  ) -> CommandOutput? {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let output = Pipe()
    let stdin = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = stdin
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return nil }
    try? stdin.fileHandleForWriting.write(contentsOf: input)
    try? stdin.fileHandleForWriting.close()
    let collected = OutputBuffer()
    let reader = Thread {
      collected.set(output.fileHandleForReading.readDataToEndOfFile())
    }
    reader.start()
    let seconds =
      Double(timeout.components.seconds)
      + Double(timeout.components.attoseconds) / 1e18
    if finished.wait(timeout: .now() + seconds) == .timedOut {
      process.terminate()
      _ = finished.wait(timeout: .now() + 2)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      return nil
    }
    collected.wait()
    return CommandOutput(
      status: process.terminationStatus, output: String(decoding: collected.data, as: UTF8.self))
  }

  final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var stored = Data()

    func set(_ data: Data) {
      lock.withLock { stored = data }
      done.signal()
    }

    func wait() { done.wait() }

    var data: Data { lock.withLock { stored } }
  }
}
