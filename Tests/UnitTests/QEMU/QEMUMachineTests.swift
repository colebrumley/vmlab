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

@Suite struct QEMUMachineStalePIDTests {
  /// BH-3: a stale pid file naming a live non-QEMU process made every start refuse with
  /// `wrong_state` ("A QEMU process already runs this VM"), though reconcile said stopped.
  @Test func launchIsNotRefusedByAStalePidFileNamingANonQEMUProcess() async throws {
    // Short, so the socket paths pass `QEMULayout.validate()` and the pid check is reached.
    let home = URL(filePath: "/tmp/vmlab-sp-\(getpid())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let layout = QEMULayout(vmDirectory: home.appending(path: "vms/vm-bh"))
    try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    try "\(getpid())\n".write(to: layout.pidFile, atomically: true, encoding: .utf8)
    let record = VMRecord(
      id: "vm-bh", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [.serial], state: .stopped)
    let plan = Plan(
      profile: .qemuHVF, guest: record.guest, resources: record.resources,
      features: record.features, estimatedStartupSeconds: 1)
    let request = QEMULaunchRequest(
      record: record, plan: plan, layout: layout, baseImage: nil,
      boot: BootSpec(mode: .kernel, kernel: "/nonexistent"),
      installation: QEMUInstallation(
        binDirectory: home.appending(path: "bin"), shareDirectory: home.appending(path: "share")))
    do {
      _ = try await QEMUMachine.launch(request)
      Issue.record("launch unexpectedly succeeded")
    } catch let error as VMLabError {
      // Any error but wrong_state: the launch got past the pid check (and failed on the missing
      // QEMU binary of this fake installation).
      #expect(error.code != .wrongState, "\(error.message)")
    }
  }
}

/// CX-23: a QEMU whose foreground parent never returns (a chardev socket waiting for a client)
/// held the start, and its slot, forever. At the deadline or on cancellation it is killed and the
/// start is `timeout`.
@Suite struct QEMUDaemonizeDeadlineTests {
  /// A stand-in QEMU that records its pid and never exits.
  static func hangingBinary() throws -> (binary: URL, pidFile: URL, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-dz-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pidFile = dir.appending(path: "parent.pid")
    let binary = dir.appending(path: "qemu-hang")
    try TestScripts.install(
      "#!/bin/bash\necho $$ > \"$(dirname \"$0\")/parent.pid\"\nexec /bin/sleep 60\n", at: binary)
    return (binary, pidFile, dir)
  }

  static func readPID(_ pidFile: URL) -> Int32? {
    (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap {
      Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  /// Whether the stand-in is gone; one killed before it wrote its pid never ran on.
  static func waitGone(_ pidFile: URL) async throws -> Bool {
    guard let pid = readPID(pidFile) else { return true }
    let deadline = ContinuousClock.now + .seconds(10)
    while LivenessProbe.processExists(pid), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    return !LivenessProbe.processExists(pid)
  }

  @Test(.timeLimit(.minutes(1))) func aStartPastTheDeadlineIsKilledAndTimesOut() async throws {
    let (binary, pidFile, dir) = try Self.hangingBinary()
    defer { try? FileManager.default.removeItem(at: dir) }
    let started = ContinuousClock.now
    await #expect {
      try await QEMUMachine.daemonize(
        binary, [], log: dir.appending(path: "qemu.log"), deadline: .seconds(1))
    } throws: { ($0 as? VMLabError)?.code == .timeout }
    #expect(ContinuousClock.now - started < .seconds(20))
    #expect(try await Self.waitGone(pidFile))
  }

  @Test(.timeLimit(.minutes(1))) func aCancelledStartIsKilled() async throws {
    let (binary, pidFile, dir) = try Self.hangingBinary()
    defer { try? FileManager.default.removeItem(at: dir) }
    let start = Task {
      try await QEMUMachine.daemonize(
        binary, [], log: dir.appending(path: "qemu.log"), deadline: .seconds(600))
    }
    let deadline = ContinuousClock.now + .seconds(20)
    while Self.readPID(pidFile) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(Self.readPID(pidFile) != nil)
    start.cancel()
    let result = await start.result
    #expect((result.error as? VMLabError)?.data["cancelled"] == .bool(true))
    #expect(try await Self.waitGone(pidFile))
  }
}

extension Result {
  var error: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
