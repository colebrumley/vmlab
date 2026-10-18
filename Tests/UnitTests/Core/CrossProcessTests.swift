import Foundation
import Testing
import VMLabCore

/// R-1100: the start gate and the per-VM operation lock across processes. Two `FileStartGate`s on
/// one home stand in for two servers: `flock` belongs to the open file, so they exclude each other
/// exactly as two processes would.
@Suite struct CrossProcessTests {
  static func home() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-xp-\(UUID())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  static let host = StartGateTests.host  // 32 GB, 4 GB reserve
  static let empty: @Sendable () -> Inventory = { .empty }

  @Test func fileLocksExcludeEachOtherAndDieWithTheirHolder() throws {
    let path = try Self.home().appending(path: "locks/x.lock").path
    var first = FileLock.tryLock(path)
    #expect(first != nil)
    #expect(FileLock.tryLock(path) == nil)
    #expect(FileLock.isHeld(path))
    first?.write(Data("hello".utf8))
    #expect(FileManager.default.contents(atPath: path) == Data("hello".utf8))
    first = nil  // deinit unlocks, as the kernel does for a process that exits
    #expect(!FileLock.isHeld(path))
    #expect(FileManager.default.contents(atPath: path) == Data())
    #expect(FileLock.tryLock(path) != nil)
  }

  @Test func twoServersShareTheMemoryBudget() async throws {
    let home = try Self.home()
    let a = FileStartGate(home: home)
    let b = FileStartGate(home: home)
    let first = try await a.admit(
      StartGateTests.linux("vm-a", 16), running: Self.empty, host: Self.host)
    // 32 - 16 in flight elsewhere - 4 reserve leaves 12.
    await #expect {
      _ = try await b.admit(StartGateTests.linux("vm-b", 16), running: Self.empty, host: Self.host)
    } throws: { StartGateTests.code($0) == .limitMemory }
    let second = try await b.admit(
      StartGateTests.linux("vm-c", 12), running: Self.empty, host: Self.host)
    await a.release(first)
    // Released: the next start sees only vm-c.
    let third = try await a.admit(
      StartGateTests.linux("vm-d", 16), running: Self.empty, host: Self.host)
    await a.release(third)
    await b.release(second)
    #expect(a.inFlight == 0 && b.inFlight == 0)
  }

  @Test func aGuestLiveInTheRecordsIsNotCountedTwice() async throws {
    let home = try Self.home()
    let a = FileStartGate(home: home)
    let b = FileStartGate(home: home)
    let permit = try await a.admit(
      StartGateTests.linux("vm-a", 16), running: Self.empty, host: Self.host)
    let live = Inventory(guests: [StartGateTests.linux("vm-a", 16)])
    let other = try await b.admit(
      StartGateTests.linux("vm-b", 12), running: { live }, host: Self.host)
    await a.release(permit)
    await b.release(other)
  }

  @Test func theMacOSLimitSpansServers() async throws {
    let home = try Self.home()
    let a = FileStartGate(home: home)
    let b = FileStartGate(home: home)
    let one = Inventory(guests: [StartGateTests.macos("m1")])
    let permit = try await a.admit(StartGateTests.macos("m2"), running: { one }, host: Self.host)
    await #expect {
      _ = try await b.admit(StartGateTests.macos("m3"), running: { one }, host: Self.host)
    } throws: { StartGateTests.code($0) == .limitMacOSGuests }
    await a.release(permit)
  }

  @Test func slotsAreSharedAndAWaiterGetsTheFreedOne() async throws {
    let home = try Self.home()
    let limits = ResourceLimits(parallelStarts: 1)
    let a = FileStartGate(home: home, limits: limits, pollInterval: .milliseconds(10))
    let b = FileStartGate(home: home, limits: limits, pollInterval: .milliseconds(10))
    let held = try await a.admit(
      StartGateTests.linux("vm-a", 1), running: Self.empty, host: Self.host)
    let waiting = Task {
      try await b.admit(StartGateTests.linux("vm-b", 1), running: Self.empty, host: Self.host)
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(b.inFlight == 0)  // still waiting for the only slot
    await a.release(held)
    let permit = try await waiting.value
    #expect(b.inFlight == 1)
    await b.release(permit)
  }

  @Test func aCancelledWaiterStopsWaiting() async throws {
    let home = try Self.home()
    let limits = ResourceLimits(parallelStarts: 1)
    let a = FileStartGate(home: home, limits: limits, pollInterval: .milliseconds(10))
    let held = try await a.admit(
      StartGateTests.linux("vm-a", 1), running: Self.empty, host: Self.host)
    let waiting = Task {
      try await a.admit(StartGateTests.linux("vm-b", 1), running: Self.empty, host: Self.host)
    }
    try await Task.sleep(for: .milliseconds(50))
    waiting.cancel()
    await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    await a.release(held)
  }

  @Test func aStaleSlotFileIsIgnored() async throws {
    let home = try Self.home()
    let dir = home.appending(path: "locks/starts")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Left by a server that crashed mid-start: the contents remain, the lock does not.
    try Data(#"{"id":"vm-z","profile":"vz-linux","os":"linux","memoryGB":28,"pid":1}"#.utf8)
      .write(to: dir.appending(path: "slot-3.lock"))
    let gate = FileStartGate(home: home)
    let permit = try await gate.admit(
      StartGateTests.linux("vm-a", 20), running: Self.empty, host: Self.host)
    await gate.release(permit)
  }

  @Test func actionsOnOneVMAreSerializedAcrossManagers() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    // A second manager on the same store stands in for the other server.
    let registry = BackendRegistry()
    registry.register(f.backend)
    let other = VMManager(store: f.store, backends: registry, readiness: FakeReadiness())
    let lock = try #require(FileLock.tryLock(f.store.operationLockPath(of: vm.id)))
    let started = Task { try await other.perform(.start, on: vm.id) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(try f.store.load(id: vm.id).state == .created)  // waiting for the other server
    lock.unlock()
    let record = try await started.value
    #expect(record?.state == .running)
    // Held by nobody once the action is over.
    #expect(!FileLock.isHeld(f.store.operationLockPath(of: vm.id)))
  }
}
