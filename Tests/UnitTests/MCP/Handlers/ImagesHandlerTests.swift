import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `images` list, pull and remove over the fixture catalogue.
@Suite struct ImagesHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  static func images(_ arguments: [String: JSONValue], in f: Fixture) async throws(VMLabError)
    -> ToolResult
  {
    try await ToolHandlers.call("images", arguments: .object(arguments), context: f.context)
  }

  @Test func pullListRemove() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let before = try await Self.images(["action": .string("list")], in: f)
    let rows = before.value["images"]?.arrayValue ?? []
    #expect(rows.map { $0["name"]?.stringValue } == ["tiny-arm64", "tiny-mac"])
    #expect(rows.first?["pulled"] == .bool(false))
    #expect(rows.first?["arch"] == .string("arm64"))

    let pulled = try await Self.images(
      ["action": .string("pull"), "name": .string("tiny-arm64")], in: f)
    #expect(pulled.value["cached"] == .bool(false))
    #expect((pulled.value["bytes"]?.numberValue ?? 0) > 0)
    #expect(f.progress.messages.first == "pulling image tiny-arm64")
    let again = try await Self.images(
      ["action": .string("pull"), "name": .string("tiny-arm64")], in: f)
    #expect(again.value["cached"] == .bool(true))

    let after = try await Self.images(["action": .string("list")], in: f)
    #expect(after.value["images"]?.arrayValue?.first?["pulled"] == .bool(true))

    let removed = try await Self.images(
      ["action": .string("remove"), "name": .string("tiny-arm64")], in: f)
    #expect(removed.value["removed"] == .array([.string("tiny-arm64")]))
    #expect((removed.value["bytesFreed"]?.numberValue ?? 0) > 0)
    let none = try await Self.images(
      ["action": .string("remove"), "name": .string("tiny-arm64")], in: f)
    #expect(none.value["removed"] == .array([]))
  }

  @Test func refusals() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let unknown = await #expect(throws: VMLabError.self) {
      try await Self.images(["action": .string("pull"), "name": .string("nope")], in: f)
    }
    #expect(unknown?.code == .imageNotFound)
    let unnamed = await #expect(throws: VMLabError.self) {
      try await Self.images(["action": .string("pull")], in: f)
    }
    #expect(unnamed?.data["field"] == .string("name"))
    let unbuilt = await #expect(throws: VMLabError.self) {
      try await Self.images(["action": .string("template_create")], in: f)
    }
    #expect(unbuilt?.code == .invalidRequest)
  }

  /// R-1003: prune keeps what a VM uses, removes the rest, and keeps everything when a VM record
  /// cannot be read.
  @Test func pruneKeepsWhatVMsUse() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await Self.images(["action": .string("pull"), "name": .string("tiny-arm64")], in: f)
    let kernel = f.context.home.appending(path: "Image")
    try Data("kernel".utf8).write(to: kernel)
    _ = try await Self.images(
      ["action": .string("register"), "name": .string("spare"), "kernel": .string(kernel.path)],
      in: f)
    _ = try await f.create(["autostart": .bool(false)])

    let broken = f.context.store.vmsDirectory.appending(path: "vm-zzzzzz")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: broken.appending(path: "vm.json"))
    let careful = try await Self.images(["action": .string("prune")], in: f)
    #expect(careful.value["removed"] == .array([]))
    #expect(careful.warnings.first?.contains("vm-zzzzzz") == true, "\(careful.warnings)")
    try FileManager.default.removeItem(at: broken)

    let pruned = try await Self.images(["action": .string("prune")], in: f)
    #expect(pruned.value["removed"] == .array([.string("spare")]))
    #expect(pruned.value["kept"] == .array([.string("tiny-arm64")]))
    #expect(f.context.images.pulled("tiny-arm64") != nil)
  }

  /// R-1003: a pull over 10 GB, by images pull or by vm_create, needs confirm: true.
  @Test func largePullsNeedConfirm() async throws {
    var catalogue = try ImagesTests.catalogue()
    catalogue.images[0].approxBytes = 12 << 30
    let f = try Fixture(catalogue: catalogue)
    defer { f.cleanUp() }
    let refused = await #expect(throws: VMLabError.self) {
      try await Self.images(["action": .string("pull"), "name": .string("tiny-arm64")], in: f)
    }
    #expect(refused?.code == .confirmRequired)
    #expect(refused?.data["bytes"] == .number(Double(12 << 30)))
    let viaCreate = await #expect(throws: VMLabError.self) { try await f.create() }
    #expect(viaCreate?.code == .confirmRequired)
    #expect(f.vmDirectories().isEmpty)
    let pulled = try await Self.images(
      ["action": .string("pull"), "name": .string("tiny-arm64"), "confirm": .bool(true)], in: f)
    #expect(pulled.value["cached"] == .bool(false))
  }

  /// R-1002: register a local raw disk through the tool; it lists as an arm64 raw image.
  @Test func registerADisk() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let disk = f.context.home.appending(path: "local.raw")
    try Data(repeating: 1, count: 512).write(to: disk)
    let registered = try await Self.images(
      [
        "action": .string("register"), "name": .string("local"), "path": .string(disk.path),
        "guest": .string("linux"), "arch": .string("arm64"), "format": .string("raw"),
      ], in: f)
    #expect(registered.value["format"] == .string("raw"))
    #expect(registered.value["arch"] == .string("arm64"))
    #expect(registered.value["files"]?.arrayValue?.count == 2)
    let rows = try await Self.images(["action": .string("list")], in: f)
    #expect(
      rows.value["images"]?.arrayValue?.contains {
        $0["name"] == .string("local") && $0["pulled"] == .bool(true)
      } == true)
    let noPath = await #expect(throws: VMLabError.self) {
      try await Self.images(["action": .string("register"), "name": .string("x")], in: f)
    }
    #expect(noPath?.data["field"] == .string("path"))
    let badFormat = await #expect(throws: VMLabError.self) {
      try await Self.images(
        [
          "action": .string("register"), "name": .string("y"), "path": .string(disk.path),
          "format": .string("vmdk"),
        ], in: f)
    }
    #expect(badFormat?.data["field"] == .string("format"))
    // R-1102: register paths obey the path policy.
    for (key, value) in [("path", "/etc/hosts"), ("kernel", "/System/kernel"), ("path", "rel.raw")]
    {
      let outside = await #expect(throws: VMLabError.self) {
        try await Self.images(
          ["action": .string("register"), "name": .string("z"), key: .string(value)], in: f)
      }
      #expect(outside?.data["field"] == .string(key), "\(key) \(value)")
    }
  }

  /// R-305: register a kernel, then extract_kernel from a pulled image's ext4 root.
  @Test func registerAndExtractKernel() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let kernel = f.context.home.appending(path: "Image")
    try Data("kernel".utf8).write(to: kernel)
    let registered = try await Self.images(
      [
        "action": .string("register"), "name": .string("bare"), "kernel": .string(kernel.path),
        "arch": .string("arm64"),
      ], in: f)
    #expect(registered.value["kernel"]?.stringValue?.hasSuffix("bare/kernel/vmlinuz") == true)
    #expect(registered.value["initrd"] == .null)
    let rows = try await Self.images(["action": .string("list")], in: f)
    #expect(
      rows.value["images"]?.arrayValue?.contains {
        $0["name"] == .string("bare") && $0["format"] == .string("kernel")
      } == true)

    let notPulled = await #expect(throws: VMLabError.self) {
      try await Self.images(
        ["action": .string("extract_kernel"), "name": .string("tiny-arm64")], in: f)
    }
    #expect(notPulled?.code == .imageNotFound)

    let folder = f.context.images.imageDirectory("disk")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Ext4Fixture.build().write(to: folder.appending(path: "disk.raw"))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(
      PulledImage(
        name: "disk", guest: GuestSpec(os: .linux, arch: .arm64), source: "test", format: .raw,
        checksum: nil, files: ["raw": "disk.raw"], login: ImageLogin(user: "debian"),
        pulledAt: Date())
    ).write(to: folder.appending(path: "image.json"))
    let extracted = try await Self.images(
      ["action": .string("extract_kernel"), "name": .string("disk")], in: f)
    #expect(extracted.value["version"] == .string("6.10.0"))
    #expect(extracted.value["files"]?.arrayValue?.count == 4)
  }

  /// R-1202: `none` is reserved for a bare machine; no images action takes it as a name.
  @Test func noneIsAReservedName() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let file = FileManager.default.temporaryDirectory.appending(
      path: "vmlab-none-\(UUID().uuidString)")
    try Data([0]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    _ = try await f.create(["autostart": .bool(false)])
    for arguments: [String: JSONValue] in [
      ["action": .string("pull")],
      ["action": .string("remove")],
      ["action": .string("extract_kernel")],
      ["action": .string("template_create"), "vm": .string("web")],
      ["action": .string("register"), "kernel": .string(file.path)],
      ["action": .string("register"), "path": .string(file.path)],
      ["action": .string("register"), "path": .string(file.path + ".ipsw")],
    ] {
      var arguments = arguments
      arguments["name"] = .string("none")
      let error = await #expect(throws: VMLabError.self) { try await Self.images(arguments, in: f) }
      #expect(error?.code == .invalidRequest, "\(arguments)")
      #expect(error?.data["field"] == .string("name"), "\(arguments)")
    }
    #expect(!FileManager.default.fileExists(atPath: f.context.images.imageDirectory("none").path))
  }

  /// R-1202: a bare machine booting a kernel kept in an image's directory uses that image, so
  /// `remove` refuses it as it does for a VM made from the image.
  @Test func aBareMachineBootingAnImagesKernelKeepsTheImage() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await Self.images(["action": .string("pull"), "name": .string("tiny-arm64")], in: f)
    let kernel = f.context.images.imageDirectory("tiny-arm64").appending(path: "kernel/Image")
    try FileManager.default.createDirectory(
      at: kernel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0]).write(to: kernel)
    var requirements = try VMCreateHandlerTests.bare("kernel").objectValue ?? [:]
    requirements["boot"] = .object(["mode": .string("kernel"), "kernel": .string(kernel.path)])
    _ = try await f.create(["requirements": .object(requirements), "autostart": .bool(false)])
    #expect(f.context.images.users(of: "tiny-arm64")?.count == 1)
    // The same kernel named in another case (APFS is case-insensitive) is the same use.
    var other = try #require(try f.context.store.list().records.first)
    other.boot?.kernel = kernel.path.replacingOccurrences(of: "tiny-arm64", with: "TINY-ARM64")
    try f.context.store.save(other)
    #expect(f.context.images.users(of: "tiny-arm64")?.count == 1)
    let error = await #expect(throws: VMLabError.self) {
      try await Self.images(["action": .string("remove"), "name": .string("tiny-arm64")], in: f)
    }
    #expect(error?.data["reason"] == .string("VMs use this image"))
  }
}
