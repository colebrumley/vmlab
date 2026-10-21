import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_memory_dump`'s `local` (R-1205): the write policy of `vm_file pull`, a staged `.part` for the
/// engine and a rename into the checked directory.
@Suite struct VMMemoryDumpHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  static let range: [String: JSONValue] = ["address": .string("0x40000000"), "size": .number(16)]

  static func fixture() async throws -> Fixture {
    let f = try Fixture()
    try await VMIntrospectHandlerTests.create(in: f, require: ["serial", "memory_dump"])
    return f
  }

  /// A fresh folder under `$TMPDIR`, outside the fixture's `VMLAB_HOME`, by its canonical path.
  static func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vmlab-dump-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(filePath: PathPolicy.canonical(url.path))
  }

  static func dump(_ local: String?, in f: Fixture) async throws(VMLabError) -> ToolResult {
    var arguments = range
    if let local { arguments["local"] = .string(local) }
    return try await VMIntrospectHandlerTests.call("vm_memory_dump", arguments, in: f)
  }

  static func size(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
  }

  @Test func withoutLocalTheDumpGoesUnderDumps() async throws {
    let f = try await Self.fixture()
    defer { f.cleanUp() }
    let result = try await Self.dump(nil, in: f)
    let path = try #require(result.value["path"]?.stringValue)
    let id = try f.context.store.find("web").id
    #expect(path.hasPrefix(f.context.store.directory(of: id).appending(path: "dumps/").path))
    #expect(f.backend.dumper.requests.map(\.path.path) == [path])
  }

  @Test func localUnderTMPDIRIsStagedAndRenamedIntoPlace() async throws {
    let f = try await Self.fixture()
    defer { f.cleanUp() }
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let final = folder.appending(path: "kernel.raw")
    // A file that only shares the staged name is not the dump's to touch.
    let sibling = folder.appending(path: "kernel.raw.part")
    try Data("mine".utf8).write(to: sibling)
    let result = try await Self.dump(final.path, in: f)
    #expect(result.value["path"] == .string(final.path))
    #expect(result.value["bytes"] == .number(16))
    #expect(Self.size(final.path) == 16)
    #expect(try Data(contentsOf: sibling) == Data("mine".utf8))
    // The engine wrote `<final>.part` in a staging folder under the VM's dumps/, now gone.
    let staged = try #require(f.backend.dumper.requests.first?.path)
    let dumps = f.context.store.directory(of: try f.context.store.find("web").id)
      .appending(path: "dumps")
    #expect(staged.lastPathComponent == "kernel.raw.part")
    #expect(staged.deletingLastPathComponent().deletingLastPathComponent().path == dumps.path)
    #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
  }

  @Test func refusedPathsFailBeforeTheEngine() async throws {
    let f = try await Self.fixture()
    defer { f.cleanUp() }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for local in [
      home + "/.ssh/dump.raw", home + "/Library/dump.raw", f.context.home.path + "/dump.raw",
      "relative/dump.raw",
    ] {
      let error = await #expect(throws: VMLabError.self) { try await Self.dump(local, in: f) }
      #expect(error?.code == .invalidRequest, "\(local)")
      #expect(error?.data["field"] == .string("local"))
    }
    #expect(f.backend.dumper.requests.isEmpty)
  }

  @Test func aMissingParentIsRefused() async throws {
    let f = try await Self.fixture()
    defer { f.cleanUp() }
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let error = await #expect(throws: VMLabError.self) {
      try await Self.dump(folder.appending(path: "missing/dump.raw").path, in: f)
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("local"))
    #expect(f.backend.dumper.requests.isEmpty)
  }

  @Test func aDirectoryGetsTheDefaultName() async throws {
    let f = try await Self.fixture()
    defer { f.cleanUp() }
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = try await Self.dump(folder.path, in: f)
    let path = try #require(result.value["path"]?.stringValue)
    #expect(path.hasPrefix(folder.path + "/"))
    #expect(path.hasSuffix("-0x40000000-16.raw"))
    #expect(Self.size(path) == 16)
  }

  @Test func anExistingFileIsReplaced() async throws {
    let f = try await Self.fixture()
    defer { f.cleanUp() }
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let final = folder.appending(path: "dump.raw")
    try Data(count: 4096).write(to: final)
    _ = try await Self.dump(final.path, in: f)
    #expect(Self.size(final.path) == 16)
  }

  /// A symlink put at the final name while the engine writes is replaced by the dump; its target
  /// is untouched.
  @Test func aSymlinkPlantedAtTheFinalNameIsNotFollowed() async throws {
    let f = try await Self.fixture()
    defer { f.cleanUp() }
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let final = folder.appending(path: "dump.raw")
    let victim = folder.appending(path: "victim")
    try Data("keep".utf8).write(to: victim)
    f.backend.dumper.onDump { _ in
      try? FileManager.default.createSymbolicLink(
        atPath: final.path, withDestinationPath: victim.path)
    }
    _ = try await Self.dump(final.path, in: f)
    let type =
      try FileManager.default.attributesOfItem(atPath: final.path)[.type] as? FileAttributeType
    #expect(type == .typeRegular)
    #expect(Self.size(final.path) == 16)
    #expect(try Data(contentsOf: victim) == Data("keep".utf8))
  }
}
