import Foundation
import Testing
import VMLabCore

@Suite struct VMManagerTests {
  struct Fixture {
    let store: Store
    let backend: FakeBackend
    let manager: VMManager

    init(profile: Profile = .qemuHVF, readiness: any GuestReadiness = FakeReadiness()) throws {
      let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-manager-\(UUID())")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      store = Store(home: home)
      backend = FakeBackend(profile: profile, store: store)
      let registry = BackendRegistry()
      registry.register(backend)
      manager = VMManager(store: store, backends: registry, readiness: readiness)
    }

    func plan(_ features: [Feature] = [.execSSH, .serial]) -> Plan {
      Plan(
        profile: backend.profile, guest: GuestSpec(os: .linux, arch: .arm64),
        resources: ResourceSpec(cpus: 2, memoryGB: 2, diskGB: 16), features: features,
        estimatedStartupSeconds: 10)
    }

    func create(_ features: [Feature] = [.execSSH, .serial]) async throws -> VMRecord {
      let draft = VMRecord(
        id: "", name: "web", profile: .qemuTCG, guest: GuestSpec(os: .linux, arch: .x86_64),
        features: [], image: "debian-13-arm64")
      return try await manager.create(draft, plan: plan(features))
    }

    func events(_ id: String) async throws -> [String] {
      try await EventLog(vmDirectory: store.directory(of: id)).read().events.map(\.message)
    }
  }

  @Test func fullLifecycleThroughCore() async throws {
    let f = try Fixture()
    let vm = try await f.create()
    #expect(vm.state == .created)
    #expect(vm.profile == .qemuHVF)
    #expect(vm.features == [.execSSH, .serial])
    #expect(vm.resources.memoryGB == 2)
    #expect(vm.name == "web")
    #expect(try f.store.load(id: vm.id).features == vm.features)

    var record = try #require(try await f.manager.perform(.start, on: "web"))
    #expect(record.state == .running)
    #expect(record.runtime?.pid == 4242)

    let running = try await f.manager.attach(vm.id)
    #expect(try await running.channel(.exec).run(ExecRequest(command: "uname")).stdout == "uname\n")
    _ = try running.channel(.serial)
    let missing = #expect(throws: VMLabError.self) { try running.channel(.gdb) }
    #expect(missing?.code == .capabilityMissing)
    #expect(missing?.data["feature"] == .string("gdb"))

    record = try #require(try await f.manager.perform(.pause, on: vm.id))
    #expect(record.state == .paused)
    record = try #require(try await f.manager.perform(.resume, on: vm.id))
    #expect(record.state == .running)
    record = try #require(try await f.manager.perform(.reset, on: vm.id))
    #expect(record.state == .running)
    record = try #require(try await f.manager.perform(.stop, on: vm.id))
    #expect(record.state == .stopped)
    #expect(record.runtime == nil)
    record = try #require(try await f.manager.perform(.start, on: vm.id))
    record = try #require(try await f.manager.perform(.kill, on: vm.id))
    #expect(record.state == .stopped)
    #expect(try await f.events(vm.id).contains("kill: running -> stopped"))

    #expect(try await f.manager.perform(.destroy, on: vm.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: f.store.directory(of: vm.id).path))
    #expect(
      f.backend.operations == [
        .create, .start, .attach, .pause, .resume, .reset, .stop, .start, .kill, .destroy,
      ])
  }

  /// CX-5: `require: [net_none]` without `network.mode` stores mode `none`, so no backend
  /// attaches its default NAT; and the selector still refuses net_none with mode nat.
  @Test func netNoneWithoutAModeDisablesTheNetwork() async throws {
    let f = try Fixture()
    let draft = VMRecord(
      id: "", name: "airgap", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [], image: "debian-13-arm64")
    var plan = f.plan([.execSSH, .netNone])
    plan.requested = [.netNone]
    let vm = try await f.manager.create(draft, plan: plan)
    #expect(vm.network.mode == .disabled)
    #expect(try f.store.load(id: vm.id).network.mode == .disabled)
    let plain = try await f.create()
    #expect(plain.network.mode == nil)
    #expect(throws: VMLabError.self) {
      try Requirements(
        guest: GuestSpec(os: .linux, arch: .arm64), require: [.netNone],
        network: NetworkSpec(mode: .nat))
    }
  }

  @Test func destroyKillsALiveGuestFirst() async throws {
    let f = try Fixture()
    let vm = try await f.create()
    try await f.manager.perform(.start, on: vm.id)
    try await f.manager.perform(.destroy, on: vm.id)
    #expect(f.backend.operations.suffix(2) == [.kill, .destroy])
    #expect(throws: VMLabError.self) { try f.store.load(id: vm.id) }
  }

  @Test func illegalActionIsWrongStateAndNeverReachesTheBackend() async throws {
    let f = try Fixture()
    let vm = try await f.create()
    let error = await #expect(throws: VMLabError.self) {
      try await f.manager.perform(.pause, on: vm.id)
    }
    #expect(error?.code == .wrongState)
    #expect(error?.data["state"] == .string("created"))
    #expect(f.backend.operations == [.create])
  }

  @Test func attachNeedsALiveGuest() async throws {
    let f = try Fixture()
    let vm = try await f.create()
    let error = await #expect(throws: VMLabError.self) { try await f.manager.attach(vm.id) }
    #expect(error?.code == .wrongState)
  }

  @Test func backendFailureLeavesTheStateAndLogsAnError() async throws {
    let f = try Fixture()
    let vm = try await f.create()
    f.backend.fail(.start)
    let error = await #expect(throws: VMLabError.self) {
      try await f.manager.perform(.start, on: vm.id)
    }
    #expect(error?.code == .engineError)
    #expect(try f.store.load(id: vm.id).state == .created)
    #expect(try await f.events(vm.id).contains { $0.hasPrefix("start failed") })
    #expect(try await f.manager.perform(.start, on: vm.id)?.state == .running)
  }

  @Test func failedCreateLeavesNoDirectory() async throws {
    let f = try Fixture()
    f.backend.fail(.create)
    await #expect(throws: VMLabError.self) { _ = try await f.create() }
    #expect(try f.store.list().records.isEmpty)
    #expect(f.backend.operations == [.create, .destroy])
  }

  @Test func cancelledCreateLeavesNoDirectory() async throws {
    let f = try Fixture()
    f.backend.delayCreate(.seconds(5))
    let task = Task { try await f.create() }
    while f.backend.operations.isEmpty { await Task.yield() }
    task.cancel()
    await #expect(throws: VMLabError.self) { _ = try await task.value }
    #expect(try f.store.list().records.isEmpty)
  }

  @Test func missingBackendIsRefusedBeforeAnythingIsStored() async throws {
    let f = try Fixture()
    let manager = VMManager(store: f.store, backends: BackendRegistry())
    let draft = VMRecord(id: "", profile: .qemuHVF, guest: f.plan().guest, features: [])
    await #expect(throws: VMLabError.self) { _ = try await manager.create(draft, plan: f.plan()) }
    #expect(try f.store.list().records.isEmpty)
  }

  @Test func concurrentActionsOnOneVMAreSerialized() async throws {
    let f = try Fixture()
    let vm = try await f.create()
    let results = await withTaskGroup(of: VMLabError?.self) { group in
      for _ in 0..<4 {
        group.addTask {
          do throws(VMLabError) { try await f.manager.perform(.start, on: vm.id) } catch {
            return error
          }
          return nil
        }
      }
      var errors: [VMLabError?] = []
      for await result in group { errors.append(result) }
      return errors
    }
    #expect(results.count(where: { $0 == nil }) == 1)
    #expect(results.compactMap { $0 }.allSatisfy { $0.code == .wrongState })
    #expect(f.backend.operations.count(where: { $0 == .start }) == 1)
  }

  @Test func createMakesTheSSHKeyPair() async throws {
    let f = try Fixture()
    let vm = try await f.create()
    let dir = f.store.directory(of: vm.id)
    let pub = try String(contentsOf: dir.appending(path: "id_ed25519.pub"), encoding: .utf8)
    #expect(pub.hasPrefix("ssh-ed25519 "))
    #expect(pub.contains("vmlab-\(vm.id)"))
  }

  @Test func startWaitsForSSHWhenExecSSHIsGranted() async throws {
    let readiness = FakeReadiness()
    let f = try Fixture(readiness: readiness)
    f.backend.reportSSHPort(50022)
    let vm = try await f.create()
    let outcome = try await f.manager.run(.start, on: vm.id)
    #expect(outcome.record?.state == .running)
    #expect(outcome.warnings.isEmpty)
    let target = try #require(readiness.targets.first)
    #expect(target.endpoint == SSHEndpoint(host: "127.0.0.1", port: 50022))
    #expect(target.user == "debian")
    #expect(target.vmDirectory == f.store.directory(of: vm.id))
  }

  @Test func aGuestThatNeverAnswersStaysRunningWithAWarning() async throws {
    let readiness = FakeReadiness(warning: "ssh_unreachable: nope")
    let f = try Fixture(readiness: readiness)
    f.backend.reportSSHPort(50022)
    let vm = try await f.create()
    let outcome = try await f.manager.run(.start, on: vm.id)
    #expect(outcome.record?.state == .running)
    #expect(outcome.warnings == ["ssh_unreachable: nope"])
    #expect(try f.store.load(id: vm.id).state == .running)
    #expect(try await f.events(vm.id).contains("ssh_unreachable: nope"))
  }

  @Test func startWithoutExecSSHDoesNotWait() async throws {
    let readiness = FakeReadiness(warning: "should not be asked")
    let f = try Fixture(readiness: readiness)
    f.backend.reportSSHPort(50022)
    let vm = try await f.create([.serial])
    let outcome = try await f.manager.run(.start, on: vm.id)
    #expect(outcome.warnings.isEmpty)
    #expect(readiness.targets.isEmpty)
  }

  /// R-1104: a guest whose CPU starts halted answers nothing until a debugger continues it, so
  /// its start does not wait out the SSH timeout.
  @Test func startHaltedAtStartDoesNotWait() async throws {
    let readiness = FakeReadiness(warning: "should not be asked")
    let f = try Fixture(readiness: readiness)
    f.backend.reportSSHPort(50022)
    let draft = VMRecord(
      id: "", name: "boot", profile: .qemuTCG, guest: GuestSpec(os: .linux, arch: .x86_64),
      features: [], image: "debian-13-arm64", boot: BootSpec(haltAtStart: true))
    let vm = try await f.manager.create(draft, plan: f.plan([.execSSH, .gdb, .haltAtStart]))
    let outcome = try await f.manager.run(.start, on: vm.id)
    #expect(outcome.warnings.isEmpty)
    #expect(readiness.targets.isEmpty)
  }

  @Test func startWithNoEndpointWarnsAtOnce() async throws {
    let readiness = FakeReadiness()
    let f = try Fixture(readiness: readiness)
    let vm = try await f.create()
    let outcome = try await f.manager.run(.start, on: vm.id)
    #expect(outcome.warnings.count == 1)
    #expect(outcome.warnings[0].hasPrefix("ssh_unreachable:"))
    #expect(readiness.targets.isEmpty)
  }
}

/// `vm_lifecycle timeoutSeconds` (R-1101): the SSH wait of a start and the grace of a stop.
@Suite struct LifecycleTimeoutTests {
  @Test func stopPassesTheGraceAndKillsAGuestThatOutlastsIt() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    try await f.manager.perform(.start, on: vm.id)
    f.backend.fail(
      .stop, with: VMLabError(code: .timeout, message: "did not shut down", hint: "kill it"))
    let outcome = try await f.manager.run(.stop, on: vm.id, timeout: .seconds(7))
    #expect(outcome.record?.state == .stopped)
    #expect(outcome.record?.runtime == nil)
    #expect(f.backend.graces == [.seconds(7)])
    #expect(f.backend.operations.suffix(2) == [.stop, .kill])
    #expect(outcome.warnings.contains { $0.contains("within its grace period (7 s)") })
  }

  @Test func aStopThatFailsOtherwiseStillFails() async throws {
    let f = try VMManagerTests.Fixture()
    let vm = try await f.create()
    try await f.manager.perform(.start, on: vm.id)
    f.backend.fail(.stop)
    await #expect(throws: VMLabError.self) { try await f.manager.perform(.stop, on: vm.id) }
    #expect(try f.store.load(id: vm.id).state == .running)
    #expect(!f.backend.operations.contains(.kill))
  }

  @Test func startWaitsForSSHAsLongAsAsked() async throws {
    let readiness = FakeReadiness()
    let f = try VMManagerTests.Fixture(readiness: readiness)
    f.backend.reportSSHPort(2222)
    let vm = try await f.create()
    try await f.manager.run(.start, on: vm.id, timeout: .seconds(42))
    #expect(readiness.timeouts == [.seconds(42)])
    try await f.manager.perform(.stop, on: vm.id)
    try await f.manager.perform(.start, on: vm.id)
    #expect(readiness.timeouts.last == .seconds(180))  // Appendix G, Linux under HVF
  }
}
