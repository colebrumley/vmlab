import Foundation
import Testing
import VMLabCore

@Suite struct TemplatesTests {
  static let parentKey = "ssh-ed25519 AAAAC3NzaParentKeyBlob vmlab-vm-parent"

  /// A stopped VM in a fresh home: its disk (qcow2 overlay or raw) and public key on disk.
  static func fixture(disk: String = "disk.qcow2", state: VMState = .stopped) throws
    -> (store: Store, images: ImageStore, record: VMRecord, runner: ConvertRunner)
  {
    let (home, bin) = try ImagesTests.sandbox()
    let store = Store(home: home)
    var record = try store.create(
      VMRecord(
        id: "", name: "base", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [.execSSH], image: "debian-13-arm64"))
    record = try store.update(id: record.id) { $0.state = state }
    let dir = store.directory(of: record.id)
    try Data("disk bytes".utf8).write(to: dir.appending(path: disk))
    try Data((parentKey + "\n").utf8).write(to: dir.appending(path: "id_ed25519.pub"))
    let runner = ConvertRunner()
    let images = ImageStore(home: home, runner: runner, searchPaths: [bin.path])
    return (store, images, record, runner)
  }

  @Test func qemuVMBecomesTemplateWithBothFormats() async throws {
    let f = try Self.fixture()
    let image = try await f.images.createTemplate(
      "web", from: f.record, vmDirectory: f.store.directory(of: f.record.id))
    let folder = f.images.imageDirectory("web")
    for file in ["disk.qcow2", "disk.raw", "image.json"] {
      #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path), "\(file)")
    }
    #expect(image.files == ["qcow2": "disk.qcow2", "raw": "disk.raw"])
    #expect(image.login.user == "debian")
    #expect(image.template?.sourceVM == f.record.id)
    #expect(image.template?.revokedKeys == [Self.parentKey])
    #expect(f.images.pulled("web") == image)
    let calls = f.runner.calls.withLock { $0 }
    #expect(
      calls.map { Array($0.prefix(6)) } == [
        ["qemu-img", "convert", "-f", "qcow2", "-O", "qcow2"],
        ["qemu-img", "convert", "-f", "qcow2", "-O", "raw"],
      ])
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.images.directory.path)
    #expect(leftovers == ["web"])
    let row = f.images.list().first { $0.name == "web" }
    #expect(row?.pulled?.template != nil)
  }

  @Test func vzVMRawDiskIsCopiedAndConverted() async throws {
    let f = try Self.fixture(disk: "disk.raw")
    _ = try await f.images.createTemplate(
      "raw-tpl", from: f.record, vmDirectory: f.store.directory(of: f.record.id))
    let raw = f.images.imageDirectory("raw-tpl").appending(path: "disk.raw")
    #expect(try Data(contentsOf: raw) == Data("disk bytes".utf8))
    #expect(f.runner.calls.withLock { $0.map { $0[3] + ">" + $0[5] } } == ["raw>qcow2"])
  }

  @Test func refusals() async throws {
    let running = try Self.fixture(state: .running)
    await #expect {
      try await running.images.createTemplate(
        "t", from: running.record, vmDirectory: running.store.directory(of: running.record.id))
    } throws: { ($0 as? VMLabError)?.code == .wrongState }

    let f = try Self.fixture()
    let dir = f.store.directory(of: f.record.id)
    await #expect {
      try await f.images.createTemplate("debian-13-arm64", from: f.record, vmDirectory: dir)
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    _ = try await f.images.createTemplate("t", from: f.record, vmDirectory: dir)
    await #expect {
      try await f.images.createTemplate("t", from: f.record, vmDirectory: dir)
    } throws: { ($0 as? VMLabError)?.data["field"] == .string("name") }
  }

  @Test func failedCopyLeavesNothing() async throws {
    let (home, bin) = try ImagesTests.sandbox()
    let store = Store(home: home)
    var record = try store.create(
      VMRecord(
        id: "", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64), features: []))
    record = try store.update(id: record.id) { $0.state = .stopped }
    let dir = store.directory(of: record.id)
    try Data().write(to: dir.appending(path: "disk.qcow2"))
    try Data((Self.parentKey + "\n").utf8).write(to: dir.appending(path: "id_ed25519.pub"))
    // The fake qemu-img on the path exits 1.
    let images = ImageStore(home: home, searchPaths: [bin.path])
    await #expect {
      try await images.createTemplate("t", from: record, vmDirectory: dir)
    } throws: { ($0 as? VMLabError)?.code == .engineError }
    #expect((try? FileManager.default.contentsOfDirectory(atPath: images.directory.path)) == [])
  }

  @Test func childSeedRevokesParentKeyBeforeSSH() throws {
    var config = CloudInitConfig(
      instanceID: "vm-child1", hostname: "child", user: "debian",
      sshPublicKey: "ssh-ed25519 AAAAChildBlob vmlab-vm-child1")
    #expect(!CloudInit.cloudConfig(config).contains("bootcmd"))
    config.applyTemplate(
      TemplateInfo(
        sourceVM: "vm-parent", sourceName: "base", baseImage: "debian-13-arm64",
        revokedKeys: [Self.parentKey], createdAt: Date()))
    let text = CloudInit.cloudConfig(config)
    #expect(text.contains("bootcmd:\n  - - \"sh\"\n    - \"-c\""), "\(text)")
    #expect(
      text.contains("    - \"vmlab-revoke\"\n    - \"debian\"\n    - \"AAAAC3NzaParentKeyBlob\""))
    #expect(text.contains("package_update: false"))
    #expect(text.contains("AAAAChildBlob"))
  }
}
