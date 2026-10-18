import Foundation
import Testing
import VMLabCore

@testable import VMLabVZ

@Suite struct VZMacBackendTests {
  /// A home with `macos-base` recorded as pulled, a store, and a backend over a fake `tart`.
  static func sandbox(config: URL = TartTests.fixture) throws -> (
    home: URL, store: Store, backend: VZMacBackend, fake: FakeTart
  ) {
    let home = TartTests.temporary()
    let images = ImageStore(home: home)
    let imageDir = images.imageDirectory("macos-base")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
    let pulled = PulledImage(
      name: "macos-base", guest: GuestSpec(os: .macos, arch: .arm64),
      source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", format: .tart, checksum: nil,
      files: [:], login: ImageLogin(user: "admin", password: "admin"), pulledAt: Date(),
      tartVM: "ghcr.io/cirruslabs/macos-tahoe-base:latest")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(pulled).write(to: imageDir.appending(path: "image.json"))
    let store = Store(home: home)
    let tartHome = home.appending(path: "tart")
    let fake = FakeTart(home: tartHome, config: config)
    let tart = Tart(executable: "/opt/homebrew/bin/tart", home: tartHome, commands: fake)
    let backend = VZMacBackend(store: store, tart: { () throws(VMLabError) in tart })
    return (home, store, backend, fake)
  }

  static func create(_ store: Store) throws -> VMRecord {
    try store.create(
      VMRecord(
        id: "", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
        features: [.execSSH, .gui], image: "macos-base"))
  }

  static let plan = Plan(
    profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64), resources: ResourceSpec(),
    features: [.execSSH, .gui], estimatedStartupSeconds: 60)

  /// create runs `tart clone <ref> <vm-id>` and records the clone's directory in vm.json;
  /// destroy runs `tart delete <vm-id>`.
  @Test func createClonesAndRecordsDestroyDeletes() async throws {
    let (home, store, backend, fake) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    let record = try Self.create(store)
    try await backend.create(record, plan: Self.plan)
    let clone = home.appending(path: "tart/vms").appending(path: record.id)
    let stored = try store.load(id: record.id)
    #expect(stored.tartClone == clone.path)
    #expect(FileManager.default.fileExists(atPath: clone.appending(path: "disk.img").path))
    // R-606: the VM's key, and the legacy VNC password because gui was granted.
    let dir = store.directory(of: record.id)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "id_ed25519.pub").path))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "vnc.pass").path))

    try await backend.destroy(stored)
    #expect(!FileManager.default.fileExists(atPath: clone.path))
    #expect(
      fake.calls.withLock { $0 } == [
        ["clone", "ghcr.io/cirruslabs/macos-tahoe-base:latest", record.id],
        ["delete", record.id],
      ])
  }

  /// A clone whose layout this build cannot read is deleted again and the create fails.
  @Test func unreadableCloneIsDeleted() async throws {
    let broken = TartTests.temporary()
    defer { try? FileManager.default.removeItem(at: broken) }
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    let file = broken.appending(path: "config.json")
    try Data(#"{"version": 9}"#.utf8).write(to: file)
    let (home, store, backend, _) = try Self.sandbox(config: file)
    defer { try? FileManager.default.removeItem(at: home) }
    let record = try Self.create(store)
    let error = await #expect(throws: VMLabError.self) {
      try await backend.create(record, plan: Self.plan)
    }
    #expect(error?.code == .engineError)
    #expect(
      !FileManager.default.fileExists(
        atPath: home.appending(path: "tart/vms").appending(path: record.id).path))
    #expect(try store.load(id: record.id).tartClone == nil)
  }

  @Test func createNeedsAPulledTartImage() async throws {
    let (home, store, backend, _) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    var record = try Self.create(store)
    record.image = "debian-13-arm64"
    let error = await #expect(throws: VMLabError.self) {
      try await backend.create(record, plan: Self.plan)
    }
    #expect(error?.code == .imageNotFound)
  }

  /// The runner's decisions for a macOS guest: Mac platform and boot loader from config.json and
  /// nvram.bin, disk.img, the clone's MAC, no console, a Mac display; snapshotted.
  @Test func macOSDecisions() throws {
    let clone = TartVMFiles(directory: URL(filePath: "/Users/x/.tart/vms/vm-test01"))
    let tart = try TartVMConfig.read(from: TartTests.fixture.deletingLastPathComponent())
    let record = VMRecord(
      id: "vm-test01", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      features: [.execSSH], image: "macos-base")
    let decisions = try VZRunnerConfig.macOS(record: record, clone: clone, config: tart)
      .decisions(limits: MachineDecisionsTests.limits)
    try MachineDecisionsTests.assertSnapshot(decisions, "decisions-macos.json")
    #expect(decisions.platform == "mac")
    #expect(
      decisions.bootLoader
        == .macOS(
          hardwareModel: tart.hardwareModel ?? "", machineIdentifier: tart.ecid ?? "",
          auxiliaryStorage: "/Users/x/.tart/vms/vm-test01/nvram.bin"))
    #expect(decisions.cpus == 4 && decisions.memoryBytes == 8 << 30)
    #expect(decisions.storage == [.init(path: clone.disk.path, readOnly: false)])
    #expect(decisions.network.map(\.mac) == ["72:76:f4:5e:d8:14"])
    #expect(decisions.console == nil)
    #expect(decisions.graphics == .init(width: 1024, height: 768, pixelsPerInch: 72))

    // Never below the image's minimums; no NIC with network none.
    var small = record
    small.resources = ResourceSpec(cpus: 1, memoryGB: 2)
    small.network = NetworkSpec(mode: .disabled)
    let config = VZRunnerConfig.macOS(record: small, clone: clone, config: tart)
    #expect(config.cpus == 2 && config.memoryBytes == 4 << 30)
    #expect(config.network.isEmpty)
  }
}
