import Foundation
import Testing
import VMLabCore

@Suite struct LifecycleTests {
  /// The expected table, written out independently of `Lifecycle.table`: every (state, action)
  /// pair not listed must be refused.
  static let expected: [VMState: [LifecycleAction: LifecycleTarget]] = [
    .created: [.start: .state(.running), .destroy: .destroyed],
    .running: [
      .stop: .state(.stopped), .kill: .state(.stopped), .pause: .state(.paused),
      .reset: .state(.running), .checkpointStop: .state(.suspended), .destroy: .destroyed,
    ],
    .paused: [
      .resume: .state(.running), .stop: .state(.stopped), .kill: .state(.stopped),
      .destroy: .destroyed,
    ],
    .stopped: [.start: .state(.running), .destroy: .destroyed],
    .suspended: [.start: .state(.running), .destroy: .destroyed],
    .broken: [.kill: .state(.stopped), .destroy: .destroyed],
  ]

  static let pairs: [(VMState, LifecycleAction)] = VMState.allCases.flatMap { state in
    LifecycleAction.allCases.map { (state, $0) }
  }

  @Test(arguments: pairs)
  func transition(state: VMState, action: LifecycleAction) throws {
    let legal = LifecycleAction.allCases.filter { Self.expected[state]?[$0] != nil }
    #expect(Lifecycle.legalActions(in: state) == legal)
    if let target = Self.expected[state]?[action] {
      #expect(try Lifecycle.transition(action, from: state) == target)
    } else {
      #expect(Lifecycle.target(of: action, from: state) == nil)
      do {
        _ = try Lifecycle.transition(action, from: state, vm: "web")
        Issue.record("\(action) from \(state) should be refused")
      } catch {
        #expect(error.code == .wrongState)
        #expect(error.data["state"] == .string(state.rawValue))
        #expect(error.data["legalActions"] == .array(legal.map { .string($0.rawValue) }))
        #expect(error.message.contains(state.rawValue))
        #expect(error.message.contains("web"))
        for name in legal { #expect(error.hint.contains(name.rawValue)) }
      }
    }
  }

  @Test func anyStateCanBeDestroyed() {
    for state in VMState.allCases {
      #expect(Lifecycle.target(of: .destroy, from: state) == .destroyed)
    }
  }

  // MARK: Reconcile

  /// The pid of a process that has run and been reaped.
  static func finishedPID() async throws -> Int32 {
    try await OffPool.run { () throws -> Int32 in
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/true")
      try process.run()
      process.waitUntilExit()
      return process.processIdentifier
    }
  }

  static func record(
    in store: Store, state: VMState, runtime: VMRuntime?, disk: Bool = true
  ) throws -> VMRecord {
    var record = try store.create(StoreTests.sample())
    record.state = state
    record.runtime = runtime
    try store.save(record)
    if disk {
      try Data().write(to: store.directory(of: record.id).appending(path: "disk.raw"))
    }
    return record
  }

  static func runtime(pid: Int32, home: URL) -> VMRuntime {
    VMRuntime(pid: pid, controlSocket: home.appending(path: "c.sock").path)
  }

  static func events(_ store: Store, _ id: String) async throws -> [VMEvent] {
    try await EventLog(vmDirectory: store.directory(of: id)).read().events
  }

  @Test func finishedProcessIsMarkedStopped() async throws {
    let home = try StoreTests.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let pid = try await Self.finishedPID()
    let vm = try Self.record(
      in: store, state: .running, runtime: Self.runtime(pid: pid, home: home))

    let changes = try await store.reconcile()

    #expect(changes.map(\.id) == [vm.id])
    #expect(changes.first?.from == .running)
    #expect(changes.first?.to == .stopped)
    let after = try store.load(id: vm.id)
    #expect(after.state == .stopped)
    #expect(after.runtime == nil)
    let events = try await Self.events(store, vm.id)
    #expect(events.count == 1)
    #expect(events.first?.kind == .lifecycle)
    #expect(events.first?.message.contains("\(pid)") == true)
    // A second pass finds nothing to do.
    #expect(try await store.reconcile().isEmpty)
    #expect(try await Self.events(store, vm.id).count == 1)
  }

  @Test func missingDiskIsMarkedBroken() async throws {
    let home = try StoreTests.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let pid = try await Self.finishedPID()
    let vm = try Self.record(
      in: store, state: .paused, runtime: Self.runtime(pid: pid, home: home), disk: false)

    let changes = try await store.reconcile()

    #expect(changes.first?.to == .broken)
    #expect(try store.load(id: vm.id).state == .broken)
    let events = try await Self.events(store, vm.id)
    #expect(events.first?.level == .warning)
    #expect(events.first?.message.contains("disk image is missing") == true)
  }

  /// R-1202: a bare machine has no disk, so a gone engine leaves it stopped, not broken.
  @Test func aBareMachineWithoutADiskIsStopped() async throws {
    let home = try StoreTests.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let pid = try await Self.finishedPID()
    var vm = try Self.record(
      in: store, state: .running, runtime: Self.runtime(pid: pid, home: home), disk: false)
    vm.image = nil
    vm.boot = BootSpec(mode: .kernel, kernel: "/k")
    try store.save(vm)
    #expect(vm.isBare && store.diskExists(of: vm))

    let changes = try await store.reconcile()

    #expect(changes.first?.to == .stopped)
    #expect(try store.load(id: vm.id).state == .stopped)
  }

  @Test func aliveAndAnsweringIsRunning() async throws {
    let home = try StoreTests.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let live = LivenessProbe(isAlive: { _ in true }, isAnswering: { _ in true })
    let stopped = try Self.record(
      in: store, state: .stopped, runtime: Self.runtime(pid: 4242, home: home))
    let paused = try Self.record(
      in: store, state: .paused, runtime: Self.runtime(pid: 4243, home: home))
    let running = try Self.record(
      in: store, state: .running, runtime: Self.runtime(pid: 4244, home: home))

    let changes = try await store.reconcile(probe: live)

    #expect(changes.map(\.id) == [stopped.id])
    #expect(try store.load(id: stopped.id).state == .running)
    #expect(try store.load(id: stopped.id).runtime?.pid == 4242)
    #expect(try store.load(id: paused.id).state == .paused)
    #expect(try store.load(id: running.id).state == .running)
    #expect(try await Self.events(store, running.id).isEmpty)
  }

  @Test func aliveButSilentIsTreatedAsGone() async throws {
    let home = try StoreTests.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let silent = LivenessProbe(isAlive: { _ in true }, isAnswering: { _ in false })
    let vm = try Self.record(in: store, state: .running, runtime: Self.runtime(pid: 1, home: home))

    let changes = try await store.reconcile(probe: silent)

    #expect(changes.first?.to == .stopped)
    #expect(changes.first?.reason.contains("do not answer") == true)
    #expect(try store.load(id: vm.id).runtime == nil)
  }

  @Test func recordsWithoutProcess() async throws {
    let home = try StoreTests.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let dead = LivenessProbe(isAlive: { _ in false }, isAnswering: { _ in false })
    let created = try Self.record(in: store, state: .created, runtime: nil, disk: false)
    let suspended = try Self.record(
      in: store, state: .suspended, runtime: Self.runtime(pid: 77, home: home))
    let orphan = try Self.record(in: store, state: .running, runtime: nil)

    let changes = try await store.reconcile(probe: dead)

    #expect(Set(changes.map(\.id)) == [suspended.id, orphan.id])
    #expect(try store.load(id: created.id).state == .created)
    #expect(try store.load(id: suspended.id).state == .suspended)
    #expect(try store.load(id: suspended.id).runtime == nil)
    #expect(try store.load(id: orphan.id).state == .stopped)
  }

  @Test func diskCandidatesFollowAppendixF() throws {
    let store = Store(home: URL(filePath: "/h"))
    var record = StoreTests.sample(os: .macos)
    record.id = "vm-abcdef"
    let paths = store.diskCandidates(of: record, environment: ["TART_HOME": "/t"]).map(\.path)
    #expect(
      paths == [
        "/h/vms/vm-abcdef/disk.raw", "/h/vms/vm-abcdef/disk.qcow2", "/t/vms/vm-abcdef/disk.img",
      ])
    record.profile = .qemuHVF
    #expect(store.diskCandidates(of: record).count == 2)
  }

  @Test func systemProbe() async throws {
    #expect(LivenessProbe.processExists(getpid()))
    #expect(!LivenessProbe.processExists(try await Self.finishedPID()))
    #expect(!LivenessProbe.processExists(0))
    #expect(!LivenessProbe.processExists(-1))

    let dir = URL(filePath: "/tmp/vmlab-lc-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appending(path: "c.sock").path
    #expect(!LivenessProbe.canConnect(unixSocket: path))

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      let bytes = Array(path.utf8)
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(bound == 0)
    #expect(listen(fd, 4) == 0)
    #expect(LivenessProbe.canConnect(unixSocket: path))
    #expect(
      LivenessProbe.system.isAnswering(
        VMRuntime(pid: getpid(), controlSocket: dir.appending(path: "none").path, qmpSocket: path)))
    #expect(!LivenessProbe.canConnect(unixSocket: String(repeating: "x", count: 200)))
  }
}

/// A guest that powers itself off: the engine exited, so the record follows at once.
@Suite struct EngineExitTests {
  @Test func aLiveVMWhoseEngineExitedIsStopped() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    let running = try #require(try await f.manager.perform(.start, on: vm.id))
    let pid = try #require(running.runtime?.pid)
    #expect(await f.store.recordEngineExit(id: vm.id, pid: pid + 1, reason: "x") == false)
    #expect(
      await f.store.recordEngineExit(
        id: vm.id, pid: pid, reason: "the guest powered off (QMP SHUTDOWN, reason guest-shutdown)"))
    let record = try f.store.load(id: vm.id)
    #expect(record.state == .stopped && record.runtime == nil)
    #expect(
      try await f.events(vm.id).last
        == "running -> stopped: the guest powered off (QMP SHUTDOWN, reason guest-shutdown)")
    // Once stopped, nothing more changes; start works again.
    #expect(await f.store.recordEngineExit(id: vm.id, pid: pid, reason: "x") == false)
    #expect(try await f.manager.perform(.start, on: vm.id)?.state == .running)
  }

  @Test func itWaitsForAnActionInFlight() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    let pid = try #require(try await f.manager.perform(.start, on: vm.id)?.runtime?.pid)
    let lock = try #require(FileLock.tryLock(f.store.operationLockPath(of: vm.id)))
    let exit = Task { await f.store.recordEngineExit(id: vm.id, pid: pid, reason: "off") }
    try await Task.sleep(for: .milliseconds(200))
    #expect(try f.store.load(id: vm.id).state == .running)
    lock.unlock()
    #expect(await exit.value)
  }
}

/// CX-14: a start that crashed between launching its engine and recording `runtime` left the
/// engine running unseen: reconcile ignored it, start refused ("already runs") and gc looked only
/// at VMs with no record. Each now kills such an engine, unless the VM's lock is held.
@Suite struct StrandedEngineTests {
  @Test func reconcileKillsAnEngineARecordWithoutRuntimeLeft() async throws {
    let home = try StoreTests.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let vm = try LifecycleTests.record(in: store, state: .stopped, runtime: nil)
    let engine = try await FakeEngine(vmDirectory: store.directory(of: vm.id))
    try await Task.sleep(for: .milliseconds(100))

    // A process holding the VM's lock may be starting it now: hands off.
    let held = try #require(FileLock.tryLock(store.operationLockPath(of: vm.id)))
    #expect(try await store.reconcile().isEmpty)
    #expect(engine.process.isRunning)
    held.unlock()

    let changes = try await store.reconcile()
    #expect(changes.map(\.id) == [vm.id])
    #expect(changes.first?.reason.contains("\(engine.pid)") == true)
    #expect(try await engine.waitForExit())
    #expect(try store.load(id: vm.id).state == .stopped)
    let events = try await LifecycleTests.events(store, vm.id)
    #expect(events.contains { $0.message.contains("no runtime recorded") })
  }
}
