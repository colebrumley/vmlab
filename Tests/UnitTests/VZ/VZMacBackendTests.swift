import Foundation
import Testing
import VMLabCore

@testable import VMLabVZ

@Suite struct VZMacBackendTests {
  /// A home with `macos-base` recorded as pulled, a store, and a backend over a fake `tart`.
  static func sandbox(config: URL = TartTests.fixture, password: String? = "admin") throws -> (
    home: URL, store: Store, backend: VZMacBackend, fake: FakeTart
  ) {
    let home = TartTests.temporary()
    let images = ImageStore(home: home)
    let imageDir = images.imageDirectory("macos-base")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
    let pulled = PulledImage(
      name: "macos-base", guest: GuestSpec(os: .macos, arch: .arm64),
      source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", format: .tart, checksum: nil,
      files: [:], login: ImageLogin(user: "admin", password: password), pulledAt: Date(),
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
        features: [.execSSH, .gui], image: "macos-base", plan: plan))
  }

  static let plan = Plan(
    profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64), resources: ResourceSpec(),
    features: [.execSSH, .gui], requested: [.gui], estimatedStartupSeconds: 60)

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

  /// CR-1: destroy deletes only the Tart VM named after this record's own id, never another VM's
  /// clone that a copied `tartClone` names.
  @Test func destroyNeverDeletesAnotherVMsClone() async throws {
    let (home, store, backend, fake) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    let source = try Self.create(store)
    try await backend.create(source, plan: Self.plan)
    let sourceClone = try #require(try store.load(id: source.id).tartClone)
    var other = try Self.create(store)
    other.tartClone = sourceClone
    try await backend.destroy(other)
    #expect(FileManager.default.fileExists(atPath: sourceClone))
    #expect(!(fake.calls.withLock { $0 }.contains(["delete", source.id])))
    #expect(!backend.supportsClone)
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

  /// resources.diskGB grows the clone's disk with `tart set --disk-size`; a size below the
  /// clone's is refused with invalid_request and the clone deleted.
  /// CR-2: a stored diskGB too large for bytes is refused, not a trap.
  @Test func hugeDiskGBIsRefused() async throws {
    let (home, store, backend, _) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    let record = try store.update(id: try Self.create(store).id) {
      $0.resources = ResourceSpec(diskGB: Int.max)
    }
    let error = await #expect(throws: VMLabError.self) {
      try await backend.create(record, plan: Self.plan)
    }
    #expect(error?.code == .invalidRequest)
  }

  /// CX-27: shared_dir on a macOS guest is a virtiofs device with the automount tag, which macOS
  /// mounts at /Volumes/My Shared Files by itself; a share elsewhere uses vmlab's own tag.
  @Test func sharedDirUsesTheMacOSAutomountTag() async throws {
    let clone = TartVMFiles(directory: URL(filePath: "/Users/x/.tart/vms/vm-test01"))
    let tart = try TartVMConfig.read(from: TartTests.fixture.deletingLastPathComponent())
    var record = VMRecord(
      id: "vm-test01", profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      features: [.execSSH, .sharedDir], image: "macos-base")
    record.share = SharedDirSpec(host: "/Users/x/project")
    let vm = URL(filePath: "/vm")
    let config = VZRunnerConfig.macOS(record: record, clone: clone, config: tart, vmDirectory: vm)
    #expect(
      config.directoryShares == [
        .init(tag: VZRunnerConfig.macOSAutomountTag, path: "/Users/x/project")
      ])
    #expect(VZRunnerConfig.macOSAutomountTag == "com.apple.virtio-fs.automount")
    #expect(
      try config.decisions(limits: MachineDecisionsTests.limits).fileSystems.map(\.tag) == [
        "com.apple.virtio-fs.automount"
      ])
    #expect(SharedDirSpec.of(record)?.guestPath(for: .vzMacOS) == "/Volumes/My Shared Files")
    // No share, no device.
    record.share = nil
    #expect(
      VZRunnerConfig.macOS(record: record, clone: clone, config: tart, vmDirectory: vm)
        .directoryShares.isEmpty)

    // A share elsewhere is a device under vmlab's tag, reported at its own path.
    record.share = SharedDirSpec(host: "/Users/x/project", guest: "/Users/admin/host share")
    #expect(
      VZRunnerConfig.macOS(record: record, clone: clone, config: tart, vmDirectory: vm)
        .directoryShares == [.init(tag: "vmlab-share0", path: "/Users/x/project")])
    #expect(SharedDirSpec.of(record)?.guestPath(for: .vzMacOS) == "/Users/admin/host share")

    // The image's password is enough for a share elsewhere; the automount path needs none.
    let (home, store, backend, _) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    let elsewhere = try store.update(id: try Self.create(store).id) {
      $0.share = SharedDirSpec(guest: "/Users/admin/hostshare")
    }
    try await backend.create(elsewhere, plan: Self.plan)
    let automount = try store.update(id: try Self.create(store).id) {
      $0.share = SharedDirSpec(guest: SharedDirSpec.macOSAutomountPath)
    }
    try await backend.create(automount, plan: Self.plan)
  }

  /// A share off the automount path needs sudo in the guest: with no password in the image and
  /// none given, create refuses before cloning, naming provision.sudoPassword; with
  /// `<vm>/sudo.pass` it clones, and the automount path never needs a password.
  @Test func shareElsewhereWithoutAPasswordIsRefusedBeforeCloning() async throws {
    let (home, store, backend, fake) = try Self.sandbox(password: nil)
    defer { try? FileManager.default.removeItem(at: home) }
    let elsewhere = try store.update(id: try Self.create(store).id) {
      $0.share = SharedDirSpec(guest: "/Users/admin/hostshare")
    }
    let error = await #expect(throws: VMLabError.self) {
      try await backend.create(elsewhere, plan: Self.plan)
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("provision.sudoPassword"))
    #expect(error?.hint.contains("provision.sudoPassword") == true)
    #expect(!fake.calls.withLock { $0 }.contains { $0.first == "clone" })

    try SudoPassword.write("s3cret", in: store.directory(of: elsewhere.id))
    try await backend.create(elsewhere, plan: Self.plan)
    #expect(fake.calls.withLock { $0 }.contains { $0.first == "clone" })

    let automount = try store.update(id: try Self.create(store).id) {
      $0.share = SharedDirSpec()
    }
    try await backend.create(automount, plan: Self.plan)
  }

  /// CX-28: a guest with network none has no address to provision over; that is expected, so
  /// provisioning is skipped (no error, which would kill the runner) and nothing is marked done.
  @Test func networkNoneSkipsProvisioning() async throws {
    let (home, store, backend, _) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    let record = try store.update(id: try Self.create(store).id) {
      $0.network = NetworkSpec(mode: .disabled)
    }
    try await backend.create(record, plan: Self.plan)
    try await backend.provision(try store.load(id: record.id), ip: nil)
    #expect(!MacProvisioner.isProvisioned(store.directory(of: record.id)))

    // With a network, no lease is still a provisioning failure.
    let nat = try Self.create(store)
    try await backend.create(nat, plan: Self.plan)
    let error = await #expect(throws: VMLabError.self) {
      try await backend.provision(try store.load(id: nat.id), ip: nil)
    }
    #expect(error?.code == .provisionFailed)
  }

  /// CX-29: resources below the image's minimums are raised in vm.json too, so admission and the
  /// inventory count what the guest really gets.
  @Test func createRecordsTheEffectiveResources() async throws {
    let (home, store, backend, _) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    let record = try store.update(id: try Self.create(store).id) {
      $0.resources = ResourceSpec(cpus: 1, memoryGB: 2)
    }
    try await backend.create(record, plan: Self.plan)
    let stored = try store.load(id: record.id)
    // The fixture's minimums: 2 CPUs, 4 GiB.
    #expect(stored.resources.cpus == 2 && stored.resources.memoryGB == 4)
    #expect(Inventory.Guest(record: stored).memoryGB == 4)

    // Requests at or above the minimums are kept as they are.
    let (home2, store2, backend2, _) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home2) }
    let big = try store2.update(id: try Self.create(store2).id) {
      $0.resources = ResourceSpec(memoryGB: 12)
    }
    try await backend2.create(big, plan: Self.plan)
    #expect(try store2.load(id: big.id).resources == ResourceSpec(memoryGB: 12))
  }

  @Test func diskGBGrowsTheCloneAndRefusesShrinking() async throws {
    let (home, store, backend, fake) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    var record = try store.update(id: try Self.create(store).id) {
      $0.resources = ResourceSpec(diskGB: 2)
    }
    try await backend.create(record, plan: Self.plan)
    let clone = home.appending(path: "tart/vms").appending(path: record.id)
    #expect(fake.calls.withLock { $0.contains(["set", record.id, "--disk-size", "2"]) })
    #expect(VZDisk.size(of: clone.appending(path: "disk.img")) == 2_000_000_000)

    let (home2, store2, backend2, fake2) = try Self.sandbox()
    defer { try? FileManager.default.removeItem(at: home2) }
    record = try store2.update(id: try Self.create(store2).id) {
      $0.resources = ResourceSpec(diskGB: 1)
    }
    // A clone whose disk is already 3 GB: the fake clones, then the size check runs.
    let tartHome = home2.appending(path: "tart")
    let big = Tart(
      executable: "/opt/homebrew/bin/tart", home: tartHome,
      commands: GrowingClone(inner: fake2, bytes: 3_000_000_000))
    let refusing = VZMacBackend(store: store2, tart: { () throws(VMLabError) in big })
    _ = backend2
    do {
      try await refusing.create(record, plan: Self.plan)
      Issue.record("a diskGB below the clone's disk was accepted")
    } catch {
      #expect(error.code == .invalidRequest)
      #expect(error.data["field"] == .string("resources.diskGB"))
    }
    #expect(!fake2.calls.withLock { $0.contains { $0.first == "set" } })
    #expect(
      !FileManager.default.fileExists(
        atPath: tartHome.appending(path: "vms").appending(path: record.id).path))
  }
}

/// A `tart` whose clones come out with a `bytes`-long disk.
final class GrowingClone: CommandRunning {
  let inner: FakeTart
  let bytes: UInt64
  init(inner: FakeTart, bytes: UInt64) {
    self.inner = inner
    self.bytes = bytes
  }

  func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
    let output = inner.run(executable, arguments)
    if arguments.first == "clone", arguments.count == 3, output?.status == 0 {
      let disk = inner.home.appending(path: "vms").appending(path: arguments[2]).appending(
        path: "disk.img")
      if let handle = try? FileHandle(forWritingTo: disk) {
        try? handle.truncate(atOffset: bytes)
        try? handle.close()
      }
    }
    return output
  }
}
