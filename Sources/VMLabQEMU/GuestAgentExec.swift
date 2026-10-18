import Foundation
import VMLabCore

/// `vm_exec` through qemu-guest-agent (R-403): `guest-exec` of `/bin/sh -c` with the same script
/// SSH runs (`RemoteShell.foreground`: cwd, env, `sudo -n -u` for a user other than root, its own
/// process group), then `guest-exec-status` polled until it exits. The agent runs as root, so
/// root is the "login user". It needs no guest network and works before sshd is up. At the
/// deadline a second `guest-exec` runs `RemoteShell.kill` on the group, and the refusal is
/// `timeout` with whatever output the agent returns once the group is gone.
public struct GuestAgentExecChannel: ExecChannel {
  public static let loginUser = "root"
  /// The environment the command starts with (`guest-exec` otherwise inherits the agent's).
  public static let baseEnvironment = [
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root",
    "LANG=C.UTF-8",
  ]

  public let agent: GuestAgent
  /// `<vm>/exec/`, where output scratch files and over-long logs go.
  public let execDirectory: URL
  /// The gap between status polls, growing to `maxPoll`.
  var firstPoll: Duration = .milliseconds(50)
  var maxPoll: Duration = .milliseconds(500)
  /// How long a killed command has to report its exit.
  var reapTimeout: Duration = .seconds(5)

  public init(agent: GuestAgent, vmDirectory: URL) {
    self.agent = agent
    execDirectory = vmDirectory.appending(path: "exec")
  }

  public func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
    let job = SSHExecChannel.newJobID()
    let started = ContinuousClock.now
    let deadline = started + request.timeout
    let pid = try await agent.execute(
      "guest-exec", arguments: Self.execArguments(request, job: job), timeout: .seconds(10))
    guard let pid = pid["pid"] else {
      throw VMLabError(
        code: .engineError, message: "The guest agent of \(agent.vm) returned no pid.",
        hint: "See data.raw.",
        data: ["engine": .string("qemu-ga"), "raw": .string("\(pid)")])
    }
    var gap = firstPoll
    var status: [String: JSONValue]?
    var cancelled = false
    while ContinuousClock.now < deadline {
      if Task.isCancelled {
        cancelled = true
        break
      }
      let reply = try await agent.execute("guest-exec-status", arguments: ["pid": pid])
      if reply["exited"] == .bool(true), case .object(let object) = reply {
        status = object
        break
      }
      try? await Task.sleep(for: min(gap, max(.zero, deadline - ContinuousClock.now)))
      gap = min(gap * 2, maxPoll)
    }
    let timedOut = status == nil
    if timedOut {
      // Not under the caller's task: a cancelled call still kills what it started.
      status = await Self.kill(
        job: job, pid: pid, user: request.user, agent: agent, reap: reapTimeout)
    }
    let durationMs = Int((ContinuousClock.now - started) / .milliseconds(1))
    let output = try collect(status ?? [:], job: job)
    guard !timedOut, let status else {
      throw ExecTimeout.error(
        vm: agent.vm, timeout: request.timeout, output: output, durationMs: durationMs,
        cancelled: cancelled)
    }
    return ExecResult(
      exitCode: Self.exitCode(status), stdout: output.stdout, stderr: output.stderr,
      durationMs: durationMs, truncated: output.truncated, logPath: output.logPath)
  }

  /// Kills job `job`'s process group in a detached task and waits up to `reap` for the agent to
  /// report the command's exit, which carries the output it had produced.
  static func kill(
    job: String, pid: JSONValue, user: String?, agent: GuestAgent, reap: Duration
  ) async -> [String: JSONValue]? {
    await Task.detached { () -> [String: JSONValue]? in
      _ = try? await agent.execute(
        "guest-exec",
        arguments: [
          "path": .string("/bin/sh"),
          "arg": .array([
            .string("-c"), .string(RemoteShell.kill(job: job, user: user, loginUser: loginUser)),
          ]),
          "env": .array(baseEnvironment.map { .string($0) }),
        ])
      let deadline = ContinuousClock.now + reap
      while ContinuousClock.now < deadline {
        if let reply = try? await agent.execute("guest-exec-status", arguments: ["pid": pid]),
          reply["exited"] == .bool(true), case .object(let object) = reply
        {
          return object
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return nil
    }.value
  }

  /// The `guest-exec` arguments of `request` as job `job`.
  static func execArguments(_ request: ExecRequest, job: String) -> [String: JSONValue] {
    var arguments: [String: JSONValue] = [
      "path": .string("/bin/sh"),
      "arg": .array([
        .string("-c"),
        .string(RemoteShell.foreground(request, job: job, loginUser: loginUser)),
      ]),
      "env": .array(baseEnvironment.map { .string($0) }),
      "capture-output": .bool(true),
    ]
    if let stdin = request.stdin {
      arguments["input-data"] = .string(stdin.base64EncodedString())
    }
    return arguments
  }

  /// `exitcode`, or 128 plus `signal` for a command a signal ended.
  static func exitCode(_ status: [String: JSONValue]) -> Int32 {
    if case .number(let code) = status["exitcode"] { return Int32(code) }
    if case .number(let signal) = status["signal"] { return 128 + Int32(signal) }
    return -1
  }

  /// Writes the agent's base64 output to scratch files and cuts it as SSH output is cut.
  func collect(_ status: [String: JSONValue], job: String) throws(VMLabError)
    -> ExecOutput.Collected
  {
    let files = try ExecFiles(directory: execDirectory, job: job)
    defer { files.removeScratch() }
    for (key, handle) in [("out-data", files.stdout), ("err-data", files.stderr)] {
      if let text = status[key]?.stringValue, let data = Data(base64Encoded: text) {
        try? handle.write(contentsOf: data)
      }
    }
    files.close()
    return ExecOutput.collect(
      stdout: files.stdoutURL, stderr: files.stderrURL,
      log: execDirectory.appending(path: "\(job).log"))
  }
}
