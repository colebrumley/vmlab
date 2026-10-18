import Foundation
import Synchronization
import Testing
import VMLabCore

@testable import VMLabGDB

/// The Core `DebugTarget` over the GDB client, against stubs on loopback (R-701, R-705).
@Suite struct GDBDebugTargetTests {
  /// The arm64 fixture stub, plus breakpoints, memory at 0x1000, threads, running and stops.
  static func qemuLike() throws -> FakeGDBStub.Handler {
    let base = try GDBClientTests.arm64Handler(chunk: 2000)
    let pc = Mutex<UInt64>(0x4008_0000)
    return { packet in
      switch packet {
      case "g":
        // The fixture's block with the pc the CPU has now (x0..x30 and sp come first).
        var block = Array(base("g")[0])
        let value = Array(GDBFixtures.littleEndian(pc.withLock { $0 }))
        block.replaceSubrange(512..<528, with: value)
        return [String(block)]
      case "s":
        let next = pc.withLock {
          $0 += 4
          return $0
        }
        return ["T05thread:p01.01;20:" + GDBFixtures.littleEndian(next) + ";"]
      case "c", "vCont;c:p01.02": return []
      case "^C": return ["T02thread:p01.01;"]
      case "m1000,4": return ["deadbeef"]
      case "m1000,8": return ["4142430a00ff7e20"]
      case "m9000,4": return ["E14"]
      case let p where p.hasPrefix("Z") || p.hasPrefix("z") || p.hasPrefix("M"): return ["OK"]
      case let p where p.hasPrefix("Hg"): return ["OK"]
      default: return base(packet)
      }
    }
  }

  static func endpoint(_ stub: LoopbackGDBStub) -> GDBEndpoint {
    GDBEndpoint(host: "127.0.0.1", port: stub.port)
  }

  @Test func drivesTheStubThroughCoreTypes() async throws {
    let stub = try LoopbackGDBStub(handler: try Self.qemuLike())
    let target = try await GDBDebugConnector().connect(to: Self.endpoint(stub), arch: .arm64)
    defer { Task { await target.close() } }

    let halted = try await target.halt(timeout: .seconds(2))
    #expect(halted.pc == 0x4008_0000)
    #expect(halted.signal == 5)
    #expect(halted.thread == "p01.01")

    let registers = try await target.registers(thread: nil)
    #expect(registers.first { $0.name == "pc" }?.value == "0x0000000040080000")
    #expect(registers.first { $0.name == "x0" }?.value == "0x0000000000001000")

    #expect(
      try await target.readMemory(address: 0x1000, length: 4, thread: nil) == [
        0xde, 0xad, 0xbe, 0xef,
      ])
    try await target.writeMemory(address: 0x1000, bytes: [1, 2], thread: "p01.02")
    try await target.insert(DebugPoint(address: 0x4008_0004, kind: .software))
    try await target.insert(DebugPoint(address: 0x1000, kind: .hardware))
    try await target.insert(DebugPoint(address: 0x2000, kind: .watchWrite, size: 8))
    try await target.insert(DebugPoint(address: 0x2000, kind: .watchRead, size: 4))
    try await target.insert(DebugPoint(address: 0x2000, kind: .watchAccess, size: 2))
    try await target.remove(DebugPoint(address: 0x4008_0004, kind: .software))
    #expect(
      stub.received.filter { $0.first == "Z" || $0.first == "z" || $0.hasPrefix("Hg") } == [
        "Hgp01.02", "Z0,40080004,4", "Z1,1000,4", "Z2,2000,8", "Z3,2000,4", "Z4,2000,2",
        "z0,40080004,4",
      ])

    try await target.step(thread: nil)
    let stepped = try await target.waitForStop(timeout: .seconds(2))
    #expect(stepped.pc == 0x4008_0004)

    try await target.resume(thread: "p01.02")
    #expect(await target.isRunning)
    let interrupted = try await target.halt(timeout: .seconds(2))
    #expect(interrupted.signal == 2)
    #expect(await !target.isRunning)

    let refused = await #expect(throws: VMLabError.self) {
      try await target.readMemory(address: 0x9000, length: 4, thread: nil)
    }
    #expect(refused?.code == .engineError)
    #expect(refused?.data["endpoint"] == .string("127.0.0.1:\(stub.port)"))
  }

  /// R-705 Verify: the stub serves one client; a second connection is refused with debug_busy,
  /// whether the stub leaves it unanswered (QEMU) or hangs up on it.
  @Test(arguments: [LoopbackGDBStub.Others.ignore, .hangUp])
  func secondConnectionIsDebugBusy(others: LoopbackGDBStub.Others) async throws {
    let stub = try LoopbackGDBStub(others: others, handler: try Self.qemuLike())
    let endpoint = Self.endpoint(stub)
    let first = try await GDBDebugConnector().connect(to: endpoint, arch: .arm64)
    let started = ContinuousClock.now
    let error = await #expect(throws: VMLabError.self) {
      _ = try await GDBDebugConnector(replyTimeout: .milliseconds(500)).connect(
        to: endpoint, arch: .arm64)
    }
    #expect(error?.code == .debugBusy)
    #expect(error?.data["endpoint"] == .string(endpoint.address))
    // Busy rather than hanging; generous for a loaded host.
    #expect(ContinuousClock.now - started < .seconds(15))
    // The first client is unaffected.
    #expect(try await first.halt(timeout: .seconds(2)).pc == 0x4008_0000)
    await first.close()
  }

  @Test func nothingListeningIsGuestUnreachable() async throws {
    // Port 1 (tcpmux) is privileged and unused on macOS: the connect is refused.
    let port = 1
    let error = await #expect(throws: VMLabError.self) {
      _ = try await GDBDebugConnector().connect(
        to: GDBEndpoint(host: "127.0.0.1", port: port), arch: .arm64)
    }
    #expect(error?.code == .guestUnreachable)
  }

  @Test func lostConnectionIsNoticedAndSessionReconnects() async throws {
    let stub = try LoopbackGDBStub(handler: try Self.qemuLike())
    let target = try await GDBDebugConnector().connect(to: Self.endpoint(stub), arch: .arm64)
    #expect(await target.isConnected)
    stub.hangUpClient()
    let error = await #expect(throws: VMLabError.self) {
      _ = try await target.registers(thread: nil)
    }
    #expect(error?.code == .guestUnreachable)
    #expect(await !target.isConnected)
  }

  @Test(arguments: [
    (GDBError.connectionClosed, ErrorCode.guestUnreachable),
    (.timeout(seconds: 2), .timeout), (.targetRunning, .wrongState),
    (.unknownRegister("q"), .invalidRequest), (.stubError(code: 14, message: nil), .engineError),
    (.unsupported(packet: "Z1"), .engineError), (.malformedReply("x"), .engineError),
  ])
  func mapsGDBErrorsToAppendixD(error: GDBError, code: ErrorCode) {
    let mapped = error.vmLabError(endpoint: GDBEndpoint(host: "127.0.0.1", port: 1))
    #expect(mapped.code == code)
    #expect(!mapped.hint.isEmpty)
  }

  @Test func stopReasonsBecomeDebugStops() {
    let watch = GDBDebugTarget.stop(
      StopReason(
        kind: .signal, signal: 5, pc: 0x10,
        watchpoint: .init(kind: .write, address: 0x2000)))
    #expect(watch.reason == .watchpoint)
    #expect(watch.watchAddress == 0x2000)
    #expect(
      GDBDebugTarget.stop(StopReason(kind: .signal, signal: 5, breakpoint: .software)).reason
        == .breakpoint)
    #expect(GDBDebugTarget.stop(StopReason(kind: .exited(status: 0), signal: 0)).reason == .exited)
    #expect(GDBDebugTarget.stop(StopReason(kind: .signal, signal: 11)).reason == .signal)
  }
}

/// R-705: the connection belongs to a process's `DebugSessions`, not to a call.
@Suite struct DebugSessionDurabilityTests {
  static func sessions(_ dir: URL) -> DebugSessions {
    DebugSessions(connector: GDBDebugConnector(replyTimeout: .milliseconds(500)))
  }

  /// Verify: with the stub held by one server's session, a second server's session gets
  /// `debug_busy` (and stays unattached) instead of hanging; once the first lets go (its server
  /// exits), the second connects and inserts the recorded points again.
  @Test func secondServerIsBusyThenTakesOver() async throws {
    let stub = try LoopbackGDBStub(handler: try GDBDebugTargetTests.qemuLike())
    let endpoint = GDBDebugTargetTests.endpoint(stub)
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-durable-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = try await Self.sessions(dir).session(
      vm: "vm-a", endpoint: endpoint, arch: .arm64, directory: dir)
    _ = try await first.halt()
    try await first.add(DebugPoint(address: 0x4008_0004, kind: .software))
    #expect(await first.attached)

    let second = try await Self.sessions(dir).session(
      vm: "vm-a", endpoint: endpoint, arch: .arm64, directory: dir)
    let started = ContinuousClock.now
    let error = await #expect(throws: VMLabError.self) { try await second.halt() }
    #expect(error?.code == .debugBusy)
    #expect(error?.data["endpoint"] == .string(endpoint.address))
    // Busy rather than hanging; generous for a loaded host.
    #expect(ContinuousClock.now - started < .seconds(15))
    #expect(await second.attached == false)
    #expect(await second.busySince != nil)
    // The first session's connection is untouched.
    #expect(try await first.registers().contains { $0.name == "pc" })

    // The first server exits; the second reconnects and puts the recorded point back.
    await first.detach()
    let deadline = ContinuousClock.now + .seconds(5)
    var stop: DebugStop?
    while stop == nil, ContinuousClock.now < deadline {
      stop = try? await second.halt()
      if stop == nil { try await Task.sleep(for: .milliseconds(100)) }
    }
    #expect(stop?.pc == 0x4008_0000)
    #expect(await second.attached)
    #expect(await second.busySince == nil)
    #expect(await second.points == [DebugPoint(address: 0x4008_0004, kind: .software)])
    #expect(stub.received.filter { $0 == "Z0,40080004,4" }.count == 2)
    #expect(stub.received.contains("z0,40080004,4"))
    await second.detach()
  }
}
