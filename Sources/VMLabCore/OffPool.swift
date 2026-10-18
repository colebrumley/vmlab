import Foundation

/// Blocking work kept off Swift's cooperative pool. The pool has one thread per CPU; a `poll`,
/// `connect`, `read`, `waitpid` or `usleep` run directly in an `async` function holds one of them
/// until it returns, and a few such waits stall every other task in the process (a server's
/// unrelated tool calls included). `run` gives the work a thread of its own and suspends the caller
/// until it is done. It does not use `DispatchQueue.global()`, whose threads are as few as the
/// pool's and are taken by the same kind of work.
public enum OffPool {
  /// Runs `work` on a dedicated thread and returns what it returned or throws what it threw.
  /// Cancelling the caller does not interrupt `work`; pass `onCancel` to make it return early
  /// (shut a socket down, kill a process).
  public static func run<T: Sendable, E: Error>(
    _ name: String = "vmlab.blocking",
    onCancel: @escaping @Sendable () -> Void = {},
    _ work: @escaping @Sendable () throws(E) -> T
  ) async throws(E) -> T {
    let result: Result<T, E> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let thread = Thread {
          continuation.resume(returning: Result { () throws(E) -> T in try work() })
        }
        thread.name = name
        thread.stackSize = 1 << 20
        thread.start()
      }
    } onCancel: {
      onCancel()
    }
    return try result.get()
  }

  /// Sleeps for `duration` on a dedicated thread: for a wait that must go on although the task
  /// was cancelled (`Task.sleep` then returns at once).
  public static func sleep(_ duration: Duration) async {
    let micros =
      duration.components.seconds * 1_000_000
      + duration.components.attoseconds / 1_000_000_000_000
    await run("vmlab.sleep") { usleep(useconds_t(clamping: max(1000, micros))) }
  }
}
