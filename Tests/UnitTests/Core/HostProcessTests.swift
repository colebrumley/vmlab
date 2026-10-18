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
    #expect(ContinuousClock.now - started < .seconds(5))
  }

  @Test func missingExecutableIsHostMissingTool() async {
    let error = await #expect(throws: VMLabError.self) {
      try await HostProcess.run("/nonexistent/tool", [])
    }
    #expect(error?.code == .hostMissingTool)
  }
}
