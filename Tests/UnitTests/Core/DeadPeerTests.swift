import Foundation
import Testing
import VMLabCore

@Suite struct DeadPeerTests {
  @Test func windowIsAppendixG() {
    #expect(DeadPeer.window == .seconds(5))
    #expect(DeadPeer.probeInterval < DeadPeer.window)
  }

  @Test func peerClockOwesUntilSomethingArrives() {
    let start = ContinuousClock.now
    let clock = PeerClock(now: start)
    #expect(clock.overdue(window: .seconds(5), at: start + .seconds(60)) == nil)
    clock.awaiting("query-status", at: start + .seconds(1))
    clock.awaiting("cont", at: start + .seconds(2))  // the earliest debt is kept
    #expect(clock.overdue(window: .seconds(5), at: start + .seconds(5)) == nil)
    let reason = clock.overdue(window: .seconds(5), at: start + .seconds(6))
    #expect(reason == "no answer for 5.0 s while waiting for query-status")
    clock.received(at: start + .seconds(6))
    #expect(!clock.isOwed)
    #expect(clock.idle(at: start + .seconds(8)) == .seconds(2))
  }

  @Test func errorCarriesTheReason() {
    let error = DeadPeer.error(
      channel: "qmp", endpoint: "/x/qmp.sock", reason: "silent", vm: "vm-a")
    #expect(error.code == .guestUnreachable)
    #expect(DeadPeer.isDeadPeer(error))
    #expect(error.data["vm"] == .string("vm-a"))
    #expect(DeadPeer.reason(of: error) == "qmp: silent")
    #expect(!DeadPeer.isDeadPeer(VMLabError(code: .guestUnreachable, message: "m", hint: "h")))
  }

  @Test func markBrokenOnlyTouchesLiveVMs() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    #expect(await f.store.markBroken(id: vm.id, reason: "qmp: silent") == false)
    #expect(try f.store.load(id: vm.id).state == .created)
    try await f.manager.perform(.start, on: vm.id)
    #expect(await f.store.markBroken(id: vm.id, reason: "qmp: silent"))
    let broken = try f.store.load(id: vm.id)
    #expect(broken.state == .broken)
    #expect(broken.brokenReason == "qmp: silent")
    #expect(try await f.events(vm.id).contains("running -> broken: qmp: silent"))
    #expect(await f.store.markBroken(id: "vm-zzzzzz", reason: "x") == false)
  }

  @Test func killAlwaysWorksOnABrokenVMAndClearsTheReason() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    try await f.manager.perform(.start, on: vm.id)
    await f.store.markBroken(id: vm.id, reason: "qmp: silent")
    let stopped = try #require(try await f.manager.perform(.kill, on: vm.id))
    #expect(stopped.state == .stopped)
    #expect(stopped.brokenReason == nil)
    #expect(stopped.runtime == nil)
  }

  @Test func deadPeerFromAnActionMarksTheVMBroken() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    try await f.manager.perform(.start, on: vm.id)
    f.backend.fail(
      .pause, with: DeadPeer.error(channel: "control", endpoint: "/x/control.sock", reason: "hung"))
    await #expect(throws: VMLabError.self) { try await f.manager.perform(.pause, on: vm.id) }
    let record = try f.store.load(id: vm.id)
    #expect(record.state == .broken)
    #expect(record.brokenReason == "control: hung")
    #expect(Lifecycle.legalActions(in: .broken) == [.kill, .destroy])
  }

  @Test func reconcileKeepsABrokenVMWhoseEngineLives() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    try await f.manager.perform(.start, on: vm.id)
    await f.store.markBroken(id: vm.id, reason: "qmp: silent")
    let alive = LivenessProbe(isAlive: { _ in true }, isAnswering: { _ in true })
    #expect(try await f.store.reconcile(probe: alive).isEmpty)
    #expect(try f.store.load(id: vm.id).state == .broken)
    // Once the hung process is gone, the VM is stopped and the reason cleared.
    let gone = LivenessProbe(isAlive: { _ in false }, isAnswering: { _ in false })
    let changes = try await f.store.reconcile(probe: gone)
    #expect(changes.map(\.to) == [.broken])  // reconcile never un-breaks: kill does
    #expect(try f.store.load(id: vm.id).brokenReason == "qmp: silent")
  }

  @Test func brokenReasonRoundTripsAndOldRecordsLoad() throws {
    var record = VMRecord(
      id: "vm-aaaaaa", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [], state: .broken)
    record.brokenReason = "display: silent"
    let data = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(VMRecord.self, from: data).brokenReason == "display: silent")
    record.brokenReason = nil
    let plain = try JSONEncoder().encode(record)
    #expect(!String(decoding: plain, as: UTF8.self).contains("brokenReason"))
  }
}

@Suite struct GDBDeadPeerMarkingTests {
  @Test func theVMWhoseStubDiedIsMarkedBroken() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    try await f.manager.perform(.start, on: vm.id)
    try f.store.update(id: vm.id) { $0.runtime?.gdbEndpoint = "tcp:127.0.0.1:41234" }
    #expect(
      await f.store.markBroken(
        gdbEndpoint: GDBEndpoint(host: "127.0.0.1", port: 9), reason: "gdb: x") == false)
    #expect(
      await f.store.markBroken(
        gdbEndpoint: GDBEndpoint(host: "127.0.0.1", port: 41234), reason: "gdb: silent"))
    let record = try f.store.load(id: vm.id)
    #expect(record.state == .broken && record.brokenReason == "gdb: silent")
  }
}
