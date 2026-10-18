import Foundation
import Testing
import VMLabCore

private final class BundleToken {}

@Suite struct StoreTests {
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/store")

  static func tempHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-store-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func sample(name: String? = nil, os: GuestSpec.OS = .linux) -> VMRecord {
    VMRecord(
      id: "", name: name, profile: os == .macos ? .vzMacOS : .qemuHVF,
      guest: GuestSpec(os: os, arch: .arm64), features: [.execSSH, .serial, .gdb],
      resources: ResourceSpec(cpus: 2, memoryGB: 4, diskGB: 32), image: "debian-13-arm64",
      network: NetworkSpec(mode: .nat, forwards: [PortForward(guest: 22)]),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000))
  }

  /// Installs `fixture` as the `vm.json` of a VM directory and returns its ID.
  static func install(_ fixture: URL, in store: Store) throws -> String {
    let data = try Data(contentsOf: fixture)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let id = object["id"] as! String
    try FileManager.default.createDirectory(
      at: store.directory(of: id), withIntermediateDirectories: true)
    try data.write(to: store.recordURL(of: id))
    return id
  }

  @Test func defaultHome() {
    #expect(Store.defaultHome(environment: ["VMLAB_HOME": "/x/y"]).path == "/x/y")
    #expect(Store.defaultHome(environment: ["VMLAB_HOME": ""]).lastPathComponent == ".vmlab")
    #expect(Store.defaultHome(environment: [:]).lastPathComponent == ".vmlab")
  }

  @Test func roundTrip() throws {
    let home = try Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    var record = try store.create(Self.sample())
    #expect(VMRecord.isValidID(record.id))
    #expect(record.name == record.id)
    #expect(
      FileManager.default.fileExists(atPath: home.appending(path: "vms/\(record.id)/vm.json").path))

    record.state = .running
    record.runtime = VMRuntime(
      pid: 99, controlSocket: "/tmp/c.sock", qmpSocket: "/tmp/q.sock", vncSocket: "/tmp/v.sock",
      gdbEndpoint: "tcp:127.0.0.1:1234", sshPort: 2222, ip: "10.0.2.15")
    record.checkpoints = [CheckpointRef(id: "cp-1", name: "base")]
    try store.save(record)
    #expect(try store.load(id: record.id) == record)
    #expect(try store.find(record.id) == record)
    #expect(try store.list().records == [record])

    let json = try String(contentsOf: store.recordURL(of: record.id), encoding: .utf8)
    #expect(json.contains("\"schemaVersion\" : 1"))
    #expect(json.contains("\"state\" : \"running\""))
    // No temporary files are left behind.
    let files = try FileManager.default.contentsOfDirectory(
      atPath: store.directory(of: record.id).path)
    #expect(files == ["vm.json"])
  }

  @Test func namesAreUniqueAndFindable() throws {
    let home = try Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let a = try store.create(Self.sample(name: "web"))
    #expect(a.name == "web")
    #expect(try store.find("web").id == a.id)
    #expect(throws: VMLabError.self) { try store.create(Self.sample(name: "web")) }
    let b = try store.create(Self.sample())
    #expect(b.id != a.id)
    #expect(throws: VMLabError.self) { try store.update(id: b.id) { $0.name = "web" } }
    #expect(throws: VMLabError.self) { try store.create(Self.sample(name: "vm-aaaaaa")) }
    #expect(throws: VMLabError.self) { try store.create(Self.sample(name: "bad name")) }
    try store.update(id: b.id) { $0.name = "db" }
    #expect(try store.find("db").id == b.id)
    #expect(try store.list().records.map(\.name).sorted() == ["db", "web"])
  }

  @Test func missingVMIsNotFound() throws {
    let home = try Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    #expect(try store.list().records.isEmpty)
    for vm in ["vm-zzzzzz", "nothing", "../etc"] {
      let error = #expect(throws: VMLabError.self) { try store.find(vm) }
      #expect(error?.code == .vmNotFound)
      #expect(error?.data["vm"] == .string(vm))
    }
    let error = #expect(throws: VMLabError.self) { try store.load(id: "vm-zzzzzz") }
    #expect(error?.code == .vmNotFound)
  }

  @Test func removeDeletesTheDirectory() throws {
    let home = try Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let record = try store.create(Self.sample())
    try store.remove(id: record.id)
    #expect(!FileManager.default.fileExists(atPath: store.directory(of: record.id).path))
    #expect(try store.list().records.isEmpty)
  }

  @Test func idsHaveTheDocumentedForm() {
    #expect(VMRecord.isValidID("vm-abc234"))
    #expect(!VMRecord.isValidID("vm-abc23"))
    #expect(!VMRecord.isValidID("vm-ABC234"))
    #expect(!VMRecord.isValidID("vm-abc018"))
    #expect(!VMRecord.isValidID("xx-abc234"))
  }

  @Test func runningGuestsCountsLiveRecords() throws {
    let home = try Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let mac = try store.create(Self.sample(os: .macos))
    let linux = try store.create(Self.sample())
    _ = try store.create(Self.sample())
    try store.update(id: mac.id) { $0.state = .running }
    try store.update(id: linux.id) { $0.state = .paused }
    let counts = store.runningGuests()
    #expect(counts.macOS == 1 && counts.total == 2)
  }

  /// Constraint C4: a fixture exists for every released schema version and each one loads.
  @Test func everyReleasedSchemaVersionLoads() throws {
    let home = try Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    for version in 1...VMRecord.currentSchemaVersion {
      let fixture = Self.fixtures.appending(path: "vm-v\(version).json")
      #expect(FileManager.default.fileExists(atPath: fixture.path), "missing \(fixture.path)")
      let id = try Self.install(fixture, in: store)
      let record = try store.load(id: id)
      #expect(record.schemaVersion == VMRecord.currentSchemaVersion)
      #expect(record.id == id)
    }
    let v1 = try store.load(id: "vm-abc234")
    #expect(v1.name == "kernel-lab")
    #expect(v1.profile == .qemuHVF && v1.state == .running)
    #expect(v1.features == [.execSSH, .serial, .gdb, .netNAT])
    #expect(v1.runtime?.pid == 4242 && v1.runtime?.sshPort == 2222)
    #expect(v1.network.forwards == [PortForward(guest: 22, host: 2222)])
    #expect(v1.checkpoints == [CheckpointRef(id: "cp-1", name: "clean install")])
  }

  /// The registry runs each step from the file's version up to the current one.
  @Test func migrationsRunInOrder() throws {
    let data = try Data(contentsOf: Self.fixtures.appending(path: "vm-v1.json"))
    let migrations = StoreMigrations(
      steps: [
        1: { doc in doc["name"] = .string("renamed-by-v1") },
        2: { doc in
          guard case .string(let name) = doc["name"] else { return }
          doc["name"] = .string(name + "-v2")
        },
      ], currentVersion: 3)
    let record = try migrations.decode(data, source: "fixture")
    #expect(record.name == "renamed-by-v1-v2")
    #expect(record.schemaVersion == 3)

    let gap = StoreMigrations(steps: [:], currentVersion: 2)
    #expect(throws: VMLabError.self) { try gap.decode(data, source: "fixture") }
  }

  @Test func newerOrDamagedRecordsAreRefused() throws {
    let current = StoreMigrations.released
    let newer = Data(#"{"schemaVersion": 99, "id": "vm-aaaaaa"}"#.utf8)
    let error = #expect(throws: VMLabError.self) { try current.decode(newer, source: "f") }
    #expect(error?.message.contains("99") == true)
    #expect(throws: VMLabError.self) { try current.decode(Data("{".utf8), source: "f") }
    #expect(throws: VMLabError.self) { try current.decode(Data(#"{"id":"x"}"#.utf8), source: "f") }

    let home = try Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let good = try store.create(Self.sample())
    try FileManager.default.createDirectory(
      at: store.directory(of: "vm-bbbbbb"), withIntermediateDirectories: true)
    try Data("garbage".utf8).write(to: store.recordURL(of: "vm-bbbbbb"))
    let listing = try store.list()
    #expect(listing.records.map(\.id) == [good.id])
    #expect(listing.unreadable.keys.sorted() == ["vm-bbbbbb"])
  }

  /// The helper built next to this test bundle.
  static func helperURL() throws -> URL {
    let dir = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
    let url = dir.appending(path: "vmlab-store-helper")
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "no \(url.path)")
    return url
  }

  /// Two processes doing locked read-modify-writes of one record lose nothing, and a reader
  /// polling meanwhile never sees a torn file.
  @Test func concurrentSavesFromTwoProcesses() async throws {
    let home = try Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let record = try store.create(Self.sample())
    let helper = try Self.helperURL()
    let count = 150

    let processes = try ["a", "b"].map { tag in
      let process = Process()
      process.executableURL = helper
      process.arguments = [home.path, record.id, "\(count)", tag]
      try process.run()
      return process
    }
    // The polling reads and the waits run on a thread of their own, not the cooperative pool.
    let reads = try await OffPool.run { () throws(VMLabError) -> Int in
      var reads = 0
      while processes.contains(where: \.isRunning) {
        _ = try store.load(id: record.id)
        reads += 1
      }
      for process in processes { process.waitUntilExit() }
      return reads
    }
    for process in processes { #expect(process.terminationStatus == 0) }
    let final = try store.load(id: record.id)
    #expect(final.checkpoints.count == 2 * count)
    for tag in ["a", "b"] {
      let ids = final.checkpoints.map(\.id).filter { $0.hasPrefix("\(tag)-") }
      #expect(ids == (0..<count).map { "\(tag)-\($0)" })
    }
    #expect(reads > 0)
    let files = try FileManager.default.contentsOfDirectory(
      atPath: store.directory(of: record.id).path)
    #expect(files == ["vm.json"])
  }
}
