import Foundation
import Testing
import VMLabCore

@Suite struct HostProcessTests {
  @Test func passesStdinAndCollectsOutput() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "vmlab-hp-\(UUID())")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    let outcome = try await HostProcess.run(
      "/bin/cat", [], stdin: Data("hello\n".utf8), stdout: handle)
    try handle.close()
    #expect(outcome == HostProcess.Outcome(status: 0, timedOut: false))
    #expect(try String(contentsOf: url, encoding: .utf8) == "hello\n")
  }

  @Test func exitStatusIsReported() async throws {
    let outcome = try await HostProcess.run("/bin/sh", ["-c", "exit 7"])
    #expect(outcome.status == 7)
    #expect(!outcome.timedOut)
  }

  @Test func deadlineEndsTheProcess() async throws {
    let started = ContinuousClock.now
    let outcome = try await HostProcess.run("/bin/sleep", ["30"], timeout: .milliseconds(200))
    #expect(outcome.timedOut)
    // Well under the 30 s sleep; generous for a loaded host.
    #expect(ContinuousClock.now - started < .seconds(20))
  }

  @Test func missingExecutableIsHostMissingTool() async {
    let error = await #expect(throws: VMLabError.self) {
      try await HostProcess.run("/nonexistent/tool", [])
    }
    #expect(error?.code == .hostMissingTool)
  }

  /// CX-12: cancelling the caller ends a child that ignores SIGTERM with SIGKILL and reaps it
  /// before the call returns.
  @Test func cancellationKillsAChildThatIgnoresTerm() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "vmlab-hp-\(UUID())")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do sleep 0.1; done"
    let run = Task { try await HostProcess.run("/bin/sh", ["-c", script]) }
    var pid: pid_t = 0
    for _ in 0..<200 where pid == 0 {
      try await Task.sleep(for: .milliseconds(50))
      let text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
      pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    try #require(pid > 0)
    run.cancel()
    let outcome = try await run.value
    #expect(outcome.timedOut)
    #expect(outcome.status == SIGKILL)
    #expect(kill(pid, 0) == -1 && errno == ESRCH, "the child is still running")
  }

  /// A child gets only stdin, stdout and stderr: a descriptor the parent holds without
  /// close-on-exec (as another tool call's pipe would be) does not leak into it, so no reader
  /// waits for EOF on an unrelated child's lifetime. Foundation's `Process` spawns with
  /// `POSIX_SPAWN_CLOEXEC_DEFAULT` on Darwin; this pins that.
  @Test func aChildInheritsOnlyTheStandardDescriptors() async throws {
    var fds: [Int32] = [-1, -1]
    #expect(pipe(&fds) == 0)
    defer { fds.forEach { close($0) } }
    #expect(fcntl(fds[0], F_GETFD) & FD_CLOEXEC == 0)
    let url = FileManager.default.temporaryDirectory.appending(path: "vmlab-hp-\(UUID())")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    // Every descriptor 3...63 the child holds (`/dev/fd` reflects the reader's own table).
    let script = "for f in $(seq 3 63); do [ -e /dev/fd/$f ] && echo $f; done; exit 0"
    let outcome = try await HostProcess.run("/bin/sh", ["-c", script], stdout: handle)
    try handle.close()
    #expect(outcome.status == 0)
    #expect(try String(contentsOf: url, encoding: .utf8) == "")
  }
}
