import Foundation
import VMLabCore

/// Host processes a test runs, waited for off Swift's cooperative pool. Every test body runs on
/// that pool (a synchronous `@Test` too), and a `waitUntilExit`, a pipe read or a `Process.run`
/// of an executable macOS has not yet assessed holds one of its few threads; in the full parallel
/// suite a handful of them make unrelated tests queue for seconds.
enum TestProcess {
  /// Runs `executable` with `arguments` (and `stdin`, when given) to its exit and returns its
  /// status and standard output; standard error is discarded.
  static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil) async throws
    -> (status: Int32, output: Data)
  {
    let pipe = Pipe()
    let reader = pipe.fileHandleForReading
    async let output = OffPool.run { reader.readDataToEndOfFile() }
    let outcome: HostProcess.Outcome
    do {
      outcome = try await HostProcess.run(
        executable, arguments, stdin: stdin, stdout: pipe.fileHandleForWriting)
    } catch {
      try? pipe.fileHandleForWriting.close()
      _ = await output
      throw error
    }
    try? pipe.fileHandleForWriting.close()
    return (outcome.status, await output)
  }

  /// Starts `process`: `posix_spawn` returns after the exec, which for a new executable waits for
  /// macOS to assess it.
  static func start(_ process: Process) async throws {
    try await OffPool.run { () throws -> Void in try process.run() }
  }

  /// Waits for `process` to exit.
  static func waitForExit(_ process: Process) async {
    await OffPool.run { process.waitUntilExit() }
  }
}
