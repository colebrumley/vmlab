import Darwin
import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

/// A unix socket that listens and never accepts: how QEMU's QMP monitor looks to a second client
/// while another holds it (the connection waits in the backlog, ungreeted).
final class HeldMonitor: Sendable {
  let path: String
  let fd: Int32

  init() throws {
    path = "/tmp/vmlab-held-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    unlink(path)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: path.utf8)
      buf[path.utf8.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(rc == 0 && listen(fd, 4) == 0)
  }

  deinit {
    close(fd)
    unlink(path)
  }
}

@Suite struct QEMUMachineTests {
  /// R-1100: the second server gets the monitor the first one does not hold.
  @Test func attachUsesWhicheverMonitorGreets() async throws {
    let held = try HeldMonitor()
    let path = "/tmp/vmlab-qmp2-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    let free = try FakeQMPServer(path: path, connections: 1)
    defer { free.stop() }
    let started = ContinuousClock.now
    let client = try await QEMUMachine.connectFirst(
      [held.path, path], connectTimeout: .seconds(2), timeout: .seconds(20))
    #expect(ContinuousClock.now - started < .seconds(10))
    #expect(client.endpoint == path)
    #expect(try await client.queryStatus().status == "running")
    await client.close()
  }

  @Test func noFreeMonitorIsTheFirstOnesError() async throws {
    let one = try HeldMonitor()
    let two = try HeldMonitor()
    await #expect {
      _ = try await QEMUMachine.connectFirst(
        [one.path, two.path], connectTimeout: .seconds(1), timeout: .milliseconds(300))
    } throws: { ($0 as? VMLabError)?.code == .timeout }
  }

  @Test func layoutHasTwoMonitors() {
    let layout = QEMULayout(vmDirectory: URL(filePath: "/v/vm-a"))
    #expect(layout.secondaryQMPSocket.path == "/v/vm-a/qmp2.sock")
    #expect(layout.sockets.contains(layout.secondaryQMPSocket))
  }
}

/// R-304: QMP events reach the event log once, from whichever server holds the events lock.
@Suite struct QMPEventForwardingTests {
  @Test func eventsAreLoggedOnceAndTheOtherServerTakesOver() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-qmpev-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = EventLog(vmDirectory: dir)
    let lock = dir.appending(path: "vm.qmp-events.lock").path
    let (a, aIn) = AsyncStream<QMPEvent>.makeStream()
    let (b, bIn) = AsyncStream<QMPEvent>.makeStream()
    let first = Task { await QEMUBackend.forward(a, to: log, lockPath: lock) }
    let second = Task { await QEMUBackend.forward(b, to: log, lockPath: lock) }
    // Both monitors receive every event, as QEMU broadcasts them.
    let panic = QMPEvent(name: "GUEST_PANICKED", data: ["action": .string("pause")])
    aIn.yield(panic)
    try await Task.sleep(for: .milliseconds(100))
    bIn.yield(panic)
    aIn.yield(QMPEvent(name: "STOP"))  // not logged
    bIn.yield(QMPEvent(name: "STOP"))
    try await Task.sleep(for: .milliseconds(200))
    var events = try await log.read().events
    #expect(events.count == 1)
    #expect(events.first?.kind == .panic)
    // The first server goes away; the second logs from its next event.
    aIn.finish()
    await first.value
    bIn.yield(
      QMPEvent(name: "RESET", data: ["guest": .bool(true), "reason": .string("guest-reset")]))
    try await Task.sleep(for: .milliseconds(200))
    events = try await log.read().events
    #expect(
      events.map(\.message).last == "guest reset (QMP RESET, by the guest, reason guest-reset)")
    bIn.finish()
    await second.value
  }
}

@Suite struct QMPShutdownHandlingTests {
  @Test func theLockHolderHandsEventsOnAndNamesTheShutdown() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-qmpsd-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let seen = Reported()
    let (events, input) = AsyncStream<QMPEvent>.makeStream()
    let forward = Task {
      await QEMUBackend.forward(
        events, to: EventLog(vmDirectory: dir), lockPath: dir.appending(path: "l.lock").path
      ) { event in await seen.set(event.name) }
    }
    let shutdown = QMPEvent(
      name: "SHUTDOWN", data: ["guest": .bool(true), "reason": .string("guest-shutdown")])
    input.yield(shutdown)
    input.finish()
    await forward.value
    let deadline = ContinuousClock.now + .seconds(5)
    while await seen.value == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await seen.value == "SHUTDOWN")
    #expect(
      QEMUBackend.shutdownReason(shutdown)
        == "the guest powered off (QMP SHUTDOWN, reason guest-shutdown)")
    #expect(
      QEMUBackend.shutdownReason(QMPEvent(name: "SHUTDOWN", data: ["guest": .bool(false)]))
        == "QEMU shut down (QMP SHUTDOWN)")
  }
}
