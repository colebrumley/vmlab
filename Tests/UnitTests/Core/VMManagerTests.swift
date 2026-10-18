import Foundation
import Testing
import VMLabCore

@Suite struct VMManagerTests {
  struct Fixture {
    let store: Store
    let backend: FakeBackend
    let manager: VMManager

    init(profile: Profile = .qemuHVF) throws {
      let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-manager-\(UUID())")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      store = Store(home: home)
      backend = FakeBackend(profile: profile, store: store)
      let registry = BackendRegistry()
      registry.register(backend)
      manager = VMManager(store: store, backends: registry)
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
}
