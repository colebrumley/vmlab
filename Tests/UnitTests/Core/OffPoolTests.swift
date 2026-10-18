import Foundation
import Synchronization
import Testing
import VMLabCore

@Suite struct OffPoolTests {
  struct Boom: Error, Equatable {}

  final class Flag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .acquiring) }
    func set() { value.store(true, ordering: .releasing) }
  }

  @Test func returnsTheValueAndThrowsTheTypedError() async {
    #expect(await OffPool.run { 41 + 1 } == 42)
    await #expect(throws: Boom()) {
      try await OffPool.run { () throws(Boom) -> Int in throw Boom() }
    }
  }

  @Test func cancellingRunsOnCancel() async {
    let cancelled = Flag()
    let task = Task {
      await OffPool.run(onCancel: { cancelled.set() }) {
        while !cancelled.isSet { usleep(1000) }
      }
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await task.value
    #expect(cancelled.isSet)
  }

  /// More blocking waits than the pool has threads leave it free for other tasks.
  @Test func blockingWorkLeavesThePoolFree() async {
    let micros = useconds_t(PoolSaturation.hold.components.seconds * 1_000_000)
    let latency = await PoolSaturation.latency { _ in
      await OffPool.run { () -> Void in _ = usleep(micros) }
    }
    #expect(latency < PoolSaturation.budget)
  }

  /// Async callers of `CommandRunning.run` get the overload that waits off the pool (it is
  /// `OffPool.run` around the synchronous one, which `blockingWorkLeavesThePoolFree` covers;
  /// saturating the pool with real children here would hold pipes other tests' children read).
  @Test func hostCommandsRunFromAsyncCode() async {
    let output = await ProcessRunner().run("/bin/echo", ["off", "pool"])
    #expect(output == CommandOutput(status: 0, output: "off pool\n"))
  }

  @Test func sleepWaitsEvenWhenCancelled() async {
    let clock = ContinuousClock()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await clock.measure { await OffPool.sleep(.milliseconds(100)) }
    }
    #expect(await task.value >= .milliseconds(100))
  }
}
