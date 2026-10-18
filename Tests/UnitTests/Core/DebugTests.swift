import Foundation
import Testing

@testable import VMLabCore

/// `DebugSession` and `DebugSessions` against the scripted `FakeDebugTarget`.
@Suite struct DebugTests {
  static let endpoint = GDBEndpoint(host: "127.0.0.1", port: 1234)

  static func directory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-debug-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func session(
    _ connector: FakeDebugConnector = FakeDebugConnector(), directory: URL? = nil
  ) async throws -> (DebugSession, FakeDebugConnector, URL) {
    let dir = try directory ?? Self.directory()
    let sessions = DebugSessions(connector: connector)
    let session = try await sessions.session(
      vm: "vm-test", endpoint: endpoint, arch: .arm64, directory: dir)
    return (session, connector, dir)
  }

  @Test func connectsLazilyAndClassifiesStops() async throws {
    let (session, connector, dir) = try await Self.session()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(await session.attached == false)
    #expect(connector.targets.isEmpty)

    let halted = try await session.halt()
    #expect(halted.reason == .halted)
    #expect(halted.pc == 0x4008_0000)
    #expect(await session.attached)

    let stepped = try await session.step()
    #expect(stepped.reason == .step)
    #expect(stepped.pc == 0x4008_0004)

    try await session.add(DebugPoint(address: 0x4008_0100, kind: .software))
    try await session.resume()
    #expect(await session.running() == true)
    connector.latest?.stopNext(DebugStop(reason: .signal, signal: 5, pc: 0x4008_0100))
    let hit = try await session.wait(timeout: .seconds(1))
    #expect(hit.reason == .breakpoint)
    #expect(connector.targets.count == 1)
  }

  @Test func runningCPUKeepsRunningWhenAPointIsAdded() async throws {
    let (session, connector, dir) = try await Self.session()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await session.resume()
    let points = try await session.add(
      DebugPoint(address: 0x2000, kind: .watchWrite, size: 8))
    #expect(points == [DebugPoint(address: 0x2000, kind: .watchWrite, size: 8)])
    #expect(await session.running() == true)
    #expect(connector.latest?.log == ["resume", "halt", "insert watch_write 2000", "resume"])
    // Adding it again is a no-op; registers need a stopped CPU.
    try await session.add(DebugPoint(address: 0x2000, kind: .watchWrite, size: 8))
    #expect(connector.latest?.inserted.count == 1)
    let error = await #expect(throws: VMLabError.self) { try await session.registers() }
    #expect(error?.code == .wrongState)
  }

  @Test func pointsPersistAndAreReinsertedOnReconnect() async throws {
    let (session, connector, dir) = try await Self.session()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await session.add(DebugPoint(address: 0x1000, kind: .hardware))
    try await session.setSymbolFile("/tmp/vmlinux")
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "debug.json").path))

    // The stub hangs up: the next call reconnects and inserts the point again.
    connector.latest?.hangUp()
    let registers = try await session.registers()
    #expect(registers.first?.name == "pc")
    #expect(connector.targets.count == 2)
    #expect(connector.latest?.inserted == [DebugPoint(address: 0x1000, kind: .hardware)])
    #expect(connector.latest?.log.prefix(2) == ["remove hardware 1000", "insert hardware 1000"])

    // A new process (a restarted server) reads debug.json.
    let fresh = FakeDebugConnector()
    let (restarted, _, _) = try await Self.session(fresh, directory: dir)
    #expect(await restarted.points == [DebugPoint(address: 0x1000, kind: .hardware)])
    #expect(await restarted.symbolFile == "/tmp/vmlinux")
    _ = try await restarted.halt()
    #expect(fresh.latest?.inserted == [DebugPoint(address: 0x1000, kind: .hardware)])

    try await restarted.remove(address: 0x1000, kind: .hardware)
    #expect(await restarted.points.isEmpty)
    let missing = await #expect(throws: VMLabError.self) {
      try await restarted.remove(address: 0x1000, kind: .hardware)
    }
    #expect(missing?.code == .invalidRequest)
  }

  @Test func busyStubIsReportedAndRetriedLater() async throws {
    let connector = FakeDebugConnector()
    connector.setBusy(true)
    let (session, _, dir) = try await Self.session(connector)
    defer { try? FileManager.default.removeItem(at: dir) }
    let error = await #expect(throws: VMLabError.self) { try await session.halt() }
    #expect(error?.code == .debugBusy)
    #expect(await session.attached == false)
    connector.setBusy(false)
    _ = try await session.halt()
    #expect(await session.attached)
  }

  @Test func sessionsFollowANewEndpointAndNeedAConnector() async throws {
    let dir = try Self.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let none = DebugSessions()
    let error = await #expect(throws: VMLabError.self) {
      try await none.session(vm: "vm-a", endpoint: Self.endpoint, arch: .arm64, directory: dir)
    }
    #expect(error?.code == .internal)

    let connector = FakeDebugConnector()
    let sessions = DebugSessions(connector: connector)
    let first = try await sessions.session(
      vm: "vm-a", endpoint: Self.endpoint, arch: .arm64, directory: dir)
    _ = try await first.halt()
    let moved = GDBEndpoint(host: "127.0.0.1", port: 5555)
    let again = try await sessions.session(
      vm: "vm-a", endpoint: moved, arch: .arm64, directory: dir)
    #expect(again === first)
    #expect(await again.endpoint == moved)
    #expect(await again.attached == false)
    await sessions.drop("vm-a")
    #expect(sessions.existing("vm-a") == nil)
  }

  /// R-703: after a reset the points go in again; a halted reset leaves the CPU stopped, any
  /// other leaves it running if it ran; an unattached session waits for its next connect.
  @Test(arguments: [true, false])
  func afterResetReinsertsPoints(halted: Bool) async throws {
    let (session, connector, dir) = try await Self.session()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await session.afterReset(halted: halted)
    #expect(connector.targets.isEmpty)

    try await session.add(DebugPoint(address: 0x1000, kind: .hardware))
    try await session.resume()
    try await session.afterReset(halted: halted)
    let target = try #require(connector.latest)
    #expect(
      target.log.suffix(halted ? 3 : 4)
        == ["halt", "remove hardware 1000", "insert hardware 1000"] + (halted ? [] : ["resume"]))
    #expect(await session.running() == !halted)
    #expect(target.inserted == [DebugPoint(address: 0x1000, kind: .hardware)])
  }

  /// Codex CX-7: `remove` found the point's index before awaiting the stub, so two overlapping
  /// removes ended in `remove(at: 1)` on a one-element array. Run in a child process so a trap
  /// is a failure rather than the end of the test run.
  @Test func overlappingRemovesDoNotTrap() async {
    await #expect(processExitsWith: .success) {
      let (session, connector, dir) = try await DebugTests.session()
      defer { try? FileManager.default.removeItem(at: dir) }
      let a = DebugPoint(address: 0x1000, kind: .software)
      let b = DebugPoint(address: 0x2000, kind: .software)
      try await session.add(a)
      try await session.add(b)
      connector.latest?.state.withLock { $0.removeDelays[b.address] = .milliseconds(200) }
      // b's index (1) is taken first; a's remove finishes while b's still waits on the stub.
      async let slow = session.remove(address: b.address, kind: .software)
      try await Task.sleep(for: .milliseconds(50))
      let fast = try await session.remove(address: a.address, kind: .software)
      guard fast == [b] else { exit(3) }
      guard try await slow == [] else { exit(4) }
      guard await session.points.isEmpty, connector.latest?.inserted.isEmpty == true else {
        exit(5)
      }
      // A point added while a remove of another waits is kept.
      try await session.add(a)
      try await session.add(b)
      connector.latest?.state.withLock { $0.removeDelays[a.address] = .milliseconds(200) }
      async let removing = session.remove(address: a.address, kind: .software)
      try await Task.sleep(for: .milliseconds(50))
      let c = DebugPoint(address: 0x3000, kind: .software)
      try await session.add(c)
      guard try await removing == [b, c] else { exit(6) }
    }
  }

  /// A detach while a connect is in flight wins: the late connection is closed, not adopted.
  @Test func detachDuringConnectDropsTheLateConnection() async throws {
    let (session, connector, dir) = try await Self.session()
    defer { try? FileManager.default.removeItem(at: dir) }
    connector.connectDelay.withLock { $0 = .milliseconds(200) }
    let halting = Task { try await session.halt() }
    try await Task.sleep(for: .milliseconds(50))
    await session.detach()
    await #expect(throws: VMLabError.self) { try await halting.value }
    #expect(await session.attached == false)
    #expect(await connector.latest?.isConnected == false)
    // The next call connects afresh.
    connector.connectDelay.withLock { $0 = nil }
    _ = try await session.halt()
    #expect(await session.attached)
    #expect(connector.targets.count == 2)
  }
}
