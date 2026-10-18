import Darwin
import Foundation
import Synchronization

/// One host subprocess run asynchronously with an argument array (never a shell): optional bytes
/// on stdin, stdout and stderr to file handles the caller owns, and an optional deadline after
/// which it is sent `SIGTERM` and, two seconds later, `SIGKILL`. Cancelling the calling task ends
/// it the same way; either way the call returns once the process has exited and been reaped.
public enum HostProcess {
  public struct Outcome: Sendable, Hashable {
    /// The exit status, or the signal number for a process that was killed.
    public var status: Int32
    /// Whether the deadline passed (or the task was cancelled) and the process was ended for it.
    public var timedOut: Bool

    public init(status: Int32, timedOut: Bool) {
      self.status = status
      self.timedOut = timedOut
    }
  }

  public static func run(
    _ executable: String, _ arguments: [String], stdin: Data? = nil,
    stdout: FileHandle = .nullDevice, stderr: FileHandle = .nullDevice,
    timeout: Duration? = nil
  ) async throws(VMLabError) -> Outcome {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    let input = stdin.map { _ in Pipe() }
    process.standardInput = input ?? FileHandle.nullDevice
    let (statuses, continuation) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { finished in
      continuation.yield(finished.terminationStatus)
      continuation.finish()
    }
    do {
      try process.run()
    } catch {
      throw VMLabError(
        code: .hostMissingTool, message: "Cannot run \(executable): \(error)",
        hint: "\(executable) ships with macOS; check that it exists and is executable.",
        data: ["tool": .string(URL(filePath: executable).lastPathComponent)])
    }
    let pid = process.processIdentifier
    if let input, let stdin {
      // Written off the cooperative pool: a pipe blocks once its buffer is full.
      let writer = input.fileHandleForWriting
      Thread.detachNewThread {
        signal(SIGPIPE, SIG_IGN)
        try? writer.write(contentsOf: stdin)
        try? writer.close()
      }
    }
    let ended = Flag()
    let exited = Flag()
    let stop: @Sendable () -> Void = {
      guard !exited.isSet, ended.set() else {
        return
      }
      Darwin.kill(pid, SIGTERM)
      Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 2)
        if !exited.isSet { Darwin.kill(pid, SIGKILL) }
      }
    }
    let timer = timeout.map { limit in
      Task {
        do { try await Task.sleep(for: limit) } catch { return }
        stop()
      }
    }
    // The wait runs in a task of its own: an `AsyncStream` iterated under a cancelled task ends at
    // once, which would mark the child exited before the SIGKILL that a child ignoring SIGTERM
    // needs (CX-12). Awaiting `value` is not cut short by cancellation, so the call returns only
    // once the child has been reaped.
    let waiter = Task<Int32, Never> {
      var status: Int32 = -1
      for await value in statuses { status = value }
      return status
    }
    let status = await withTaskCancellationHandler {
      await waiter.value
    } onCancel: {
      stop()
    }
    _ = exited.set()
    timer?.cancel()
    withExtendedLifetime(process) {}
    return Outcome(status: status, timedOut: ended.isSet)
  }

  /// A flag set once, shared by the closures that end the process.
  final class Flag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .acquiring) }
    /// Sets the flag; true when this call set it.
    func set() -> Bool { !value.exchange(true, ordering: .acquiringAndReleasing) }
  }
}
