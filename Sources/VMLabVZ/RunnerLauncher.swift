import Foundation
import VMLabCore

/// A runner that answers on its control socket.
public struct VZRunnerHandle: Sendable, Hashable {
  public var pid: Int32
  public var paths: VZRunnerPaths
  public var client: VZControlClient
  /// The state the runner reported when it became ready.
  public var state: RunnerState

  /// `socketPath` defaults to `paths.controlSocket`.
  public init(pid: Int32, paths: VZRunnerPaths, state: RunnerState, socketPath: String? = nil) {
    self.pid = pid
    self.paths = paths
    self.client = VZControlClient(socketPath: socketPath ?? paths.controlSocket.path)
    self.state = state
  }

  /// The endpoints to record in `vm.json`.
  public var runtime: VMRuntime {
    VMRuntime(pid: pid, controlSocket: client.socketPath)
  }
}

/// Starts `vmlab-vz` runners detached from the server and reattaches to running ones.
public struct VZRunnerLauncher: Sendable {
  /// The prefix of the one line a runner writes to stderr (`vz.log`) before it exits on a startup
  /// failure, followed by the `VMLabError` as JSON.
  public static let fatalPrefix = "vmlab-vz-error: "

  /// What a missing or unentitled runner binary is told to do.
  public static let signingHint =
    "Run scripts/build.sh (or scripts/sign.sh after swift build) to sign vmlab-vz with "
    + "com.apple.security.virtualization."

  /// The `vmlab-vz` binary.
  public var runnerPath: String?
  public var commands: any CommandRunning

  public init(
    runnerPath: String? = HostProbe.defaultRunnerPath(),
    commands: any CommandRunning = ProcessRunner()
  ) {
    self.runnerPath = runnerPath
    self.commands = commands
  }

  /// The runner binary, after checking it exists and carries the virtualization entitlement;
  /// `host_missing_tool` with the signing hint otherwise.
  public func checkedRunner() throws(VMLabError) -> String {
    guard let runnerPath, FileManager.default.isExecutableFile(atPath: runnerPath) else {
      throw VMLabError(
        code: .hostMissingTool, message: "The VZ runner vmlab-vz is not built",
        hint: Self.signingHint,
        data: ["tool": .string("vmlab-vz"), "path": runnerPath.map(JSONValue.string) ?? .null])
    }
    let output =
      commands.run("/usr/bin/codesign", ["-d", "--entitlements", "-", runnerPath])?.output ?? ""
    guard CodeSignature.hasVirtualizationEntitlement(codesignOutput: output) else {
      throw Self.missingEntitlement(runnerPath)
    }
    return runnerPath
  }

  /// `checkedRunner` from an `async` context: `codesign` is waited for off the cooperative pool.
  public func checkedRunner() async throws(VMLabError) -> String {
    try await OffPool.run("vmlab.codesign") { () throws(VMLabError) -> String in
      try self.checkedRunner()
    }
  }

  static func missingEntitlement(_ path: String) -> VMLabError {
    VMLabError(
      code: .hostMissingTool,
      message: "vmlab-vz lacks the \(CodeSignature.virtualizationEntitlement) entitlement",
      hint: signingHint,
      data: [
        "tool": .string("vmlab-vz"), "path": .string(path),
        "entitlement": .string(CodeSignature.virtualizationEntitlement),
      ])
  }

  /// Writes `config` to `<vm>/vz-config.json` and starts `vmlab-vz run <vm>` with `Process`, which
  /// puts it in its own process group (the runner also ignores SIGHUP), stdin from `/dev/null`,
  /// stdout and stderr appended to `<vm>/vz.log`, so it outlives the server. Returns once the runner answers `status` with the
  /// guest `running` (or `stopped` when `hold`, which builds the machine without starting it, for
  /// `restore`). A runner that exits first reports its startup error through `vz.log`.
  public func launch(
    vmDirectory: URL, config: VZRunnerConfig, hold: Bool = false,
    readyTimeout: Duration = .seconds(60)
  ) async throws(VMLabError) -> VZRunnerHandle {
    let runner = try await checkedRunner()
    let paths = VZRunnerPaths(vmDirectory: vmDirectory)
    let socket = paths.controlSocket.path
    guard socket.utf8.count <= UnixStream.maxPathBytes else {
      throw VMLabError(
        code: .invalidRequest,
        message: "The control socket path is \(socket.utf8.count) bytes; the limit is "
          + "\(UnixStream.maxPathBytes)",
        hint: "Use a shorter VMLAB_HOME.", data: ["path": .string(socket)])
    }
    if (try? await VZControlClient(socketPath: socket).status()) != nil {
      throw VMLabError(
        code: .wrongState, message: "A VZ runner already serves \(vmDirectory.lastPathComponent)",
        hint: "Attach to it, or send it exit first.", data: ["socket": .string(socket)])
    }
    try config.write(to: paths.config)

    let logFD = open(paths.log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard logFD >= 0 else {
      throw VMLabError(
        code: .internal,
        message: "Cannot open \(paths.log.path): \(String(cString: strerror(errno)))",
        hint: "Check that the VM directory is writable.")
    }
    let logStart = lseek(logFD, 0, SEEK_END)
    let logHandle = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
    let process = Process()
    process.executableURL = URL(filePath: runner)
    process.arguments = ["run", vmDirectory.path] + (hold ? ["--hold"] : [])
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = logHandle
    process.standardError = logHandle
    do { try process.run() } catch {
      throw VMLabError(
        code: .hostMissingTool, message: "Cannot launch \(runner): \(error)",
        hint: Self.signingHint,
        data: ["tool": .string("vmlab-vz"), "path": .string(runner)])
    }
    try? logHandle.close()
    let pid = process.processIdentifier
    let ready: Set<RunnerState> = hold ? [.stopped] : [.running]
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: readyTimeout)
    while true {
      if !process.isRunning {
        throw Self.startupFailure(paths: paths, from: logStart, status: process.terminationStatus)
      }
      if let reply = try? await VZControlClient(socketPath: socket).send(
        ControlRequest(.status), timeout: .seconds(2)), let state = reply.state
      {
        if ready.contains(state) {
          return VZRunnerHandle(pid: reply.pid ?? pid, paths: paths, state: state)
        }
        if state == .error || state == .stopped {
          _ = try? await VZControlClient(socketPath: socket).exit()
          throw VMLabError(
            code: .engineError, message: "The VZ guest went \(state.rawValue) while starting",
            hint: "Check <vm>/vz.log and <vm>/console.log.",
            data: ["log": .string(paths.log.path)])
        }
      }
      if clock.now >= deadline {
        Foundation.kill(pid, SIGKILL)
        throw VMLabError(
          code: .timeout, message: "The VZ runner did not become ready within \(readyTimeout)",
          hint: "Check <vm>/vz.log; the runner was killed.",
          data: ["log": .string(paths.log.path)])
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  /// The runner's own error from the `vz.log` bytes written since `offset`, or `engine_error`
  /// with the log's tail.
  static func startupFailure(paths: VZRunnerPaths, from offset: off_t, status: Int32)
    -> VMLabError
  {
    let data = (try? Data(contentsOf: paths.log)) ?? Data()
    let tail = String(decoding: data.dropFirst(Int(max(offset, 0))), as: UTF8.self)
    return startupFailure(logText: tail, status: status, logPath: paths.log.path)
  }

  /// Parses the last `fatalPrefix` line of `logText`.
  public static func startupFailure(logText: String, status: Int32, logPath: String) -> VMLabError {
    for line in logText.split(separator: "\n").reversed() {
      guard let range = line.range(of: fatalPrefix) else { continue }
      if let error = try? JSONDecoder().decode(
        VMLabError.self, from: Data(line[range.upperBound...].utf8))
      {
        return error
      }
    }
    let lines = logText.split(separator: "\n").suffix(5).joined(separator: "\n")
    return VMLabError(
      code: .engineError, message: "The VZ runner exited with status \(status) while starting",
      hint: "Check \(logPath).",
      data: ["log": .string(logPath), "status": .number(Double(status)), "tail": .string(lines)])
  }
}

extension VMLabVZ {
  /// A client for the runner listening at `socketPath`, after it answers `status`; reconnecting
  /// needs nothing but the path, so a restarted server reattaches to the guests its predecessor
  /// started.
  public static func attach(socketPath: String) async throws(VMLabError) -> VZRunnerHandle {
    let client = VZControlClient(socketPath: socketPath)
    let reply = try await client.status()
    let directory = URL(filePath: socketPath).deletingLastPathComponent()
    let paths = VZRunnerPaths(vmDirectory: directory)
    return VZRunnerHandle(
      pid: reply.pid ?? paths.recordedPID() ?? 0, paths: paths, state: reply.state ?? .error,
      socketPath: socketPath)
  }

  /// `attach(socketPath:)` for the runner of a recorded VM.
  public static func attach(runtime: VMRuntime) async throws(VMLabError) -> VZRunnerHandle {
    try await attach(socketPath: runtime.controlSocket)
  }
}
