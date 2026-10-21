import Foundation
import Testing
import VMLabCore
import VMLabQEMU
import VMLabVZ

/// True when integration tests should run (`VMLAB_INTEGRATION=1`); they boot real guests.
let integrationEnabled = ProcessInfo.processInfo.environment["VMLAB_INTEGRATION"] == "1"

extension Tag {
  /// Minutes-long tests (TCG emulation); run them only when a Verify line names them.
  @Tag static var slow: Self
}

/// R-1207: once per test process, the homes of runs killed before their teardown are collected:
/// `vmlab-test-*` under `/tmp` (integration homes) and the temporary directory (unit-test homes)
/// whose newest file is a day old, their confirmed engines and switches ended first. The first
/// admission waits for it; the first home only starts it, since it never touches a young home.
enum TestHomeSweep {
  static let done = Task<Void, Never> {
    let lines = await GarbageCollector.sweepTestHomes(
      roots: [URL(filePath: "/tmp"), FileManager.default.temporaryDirectory],
      olderThan: .seconds(24 * 3600))
    for line in lines { print("test home sweep: \(line)") }
  }
}

/// The start gate every integration start goes through: the in-process slots and budget plus the
/// live host-memory admission a real server applies (`HostMemoryGuard`: pressure, available
/// memory, guests of every other home), so an overcommitted run fails fast with `limit_memory`
/// instead of driving the host into swap. `VMLAB_IGNORE_MEMORY_PRESSURE=1` turns the pressure
/// checks off, as for a server.
enum IntegrationAdmission {
  static let recognizers = GuestProcessRecognizers([
    VMLabQEMU.guestProcessRecognizer, VMLabVZ.guestProcessRecognizer,
  ])
  static let gate = StartGate(
    hostMemory: .live(home: Store.defaultHome(), recognizers: recognizers))

  /// `body` (a start of `vm` on `store`) run under an admitted start.
  static func start<T: Sendable>(
    _ vm: String, store: Store, _ body: () async throws -> T
  ) async throws -> T {
    await TestHomeSweep.done.value
    let record = try store.load(id: vm)
    let host = HostProbe(home: store.home, runningGuests: { store.runningGuests() }).gather()
    return try await gate.withStart(
      store.startingGuest(record), running: { store.inventory() }, host: host, body)
  }
}

extension VMManager {
  /// `perform`, with a start admitted by `IntegrationAdmission` first.
  nonisolated func performAdmitted(
    _ action: LifecycleAction, on vm: String, force: Bool = false, timeout: Duration? = nil
  ) async throws -> VMRecord? {
    guard action == .start else {
      return try await perform(action, on: vm, force: force, timeout: timeout)
    }
    return try await IntegrationAdmission.start(vm, store: store) {
      try await perform(action, on: vm, force: force, timeout: timeout)
    }
  }

  /// `run`, with a start admitted by `IntegrationAdmission` first.
  nonisolated func runAdmitted(
    _ action: LifecycleAction, on vm: String, force: Bool = false, timeout: Duration? = nil,
    sshTimeout: Duration? = nil
  ) async throws -> Outcome {
    guard action == .start else {
      return try await run(action, on: vm, force: force, timeout: timeout, sshTimeout: sshTimeout)
    }
    return try await IntegrationAdmission.start(vm, store: store) {
      try await run(action, on: vm, force: force, timeout: timeout, sshTimeout: sshTimeout)
    }
  }
}
