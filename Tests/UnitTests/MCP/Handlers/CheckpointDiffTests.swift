import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_checkpoint diff` (R-802) over stored fixture manifests, `@now` through a scripted exec
/// channel, and checkpoint names through the resolver.
@Suite struct CheckpointDiffTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  static func diff(
    _ from: String, _ to: String, in f: Fixture,
    checkpoint: @escaping CheckpointDiff.CheckpointManifest = { _ in nil }
  ) async throws(VMLabError) -> ToolResult {
    let record = try f.context.store.find("web")
    let arguments = try ToolArguments(
      .object([
        "vm": .string("web"), "action": .string("diff"), "from": .string(from),
        "to": .string(to),
      ]), spec: .vmCheckpoint)
    return try await CheckpointDiff.run(
      arguments, record: record, context: f.context, checkpointManifest: checkpoint)
  }

  /// Stores the two fixture manifests of `ManifestDiffTests` under the fixture VM.
  static func store(in f: Fixture) throws -> (GuestManifest, GuestManifest) {
    let id = try f.context.store.find("web").id
    var a = ManifestDiffTests.before()
    var b = ManifestDiffTests.after()
    a.vm = id
    b.vm = id
    try f.context.store.saveManifest(a)
    try f.context.store.saveManifest(b)
    return (a, b)
  }

  @Test func diffsTwoManifestIds() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let (a, b) = try Self.store(in: f)
    let result = try await Self.diff(a.id, b.id, in: f)
    let v = result.value
    #expect(v["from"] == .string(a.id) && v["to"] == .string(b.id))
    #expect(v["defaults"]?["changed"] == .number(1))
    let entry = v["defaults"]?["entries"]?.arrayValue?.first
    #expect(entry?["domain"] == .string("com.apple.dock"))
    #expect(entry?["key"] == .string("autohide"))
    #expect(entry?["old"] == .string("0") && entry?["new"] == .string("1"))
    #expect(v["files"]?["added"] == .number(1) && v["files"]?["changed"] == .number(3))
    #expect(v["packages"]?["truncated"] == .bool(false))
    for section in ManifestDiff.sections { #expect(v[section] != nil, "\(section)") }
    let path = try #require(v["path"]?.stringValue)
    #expect(path.hasSuffix("/manifests/diff-\(a.id)-\(b.id).json"))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(result.warnings.isEmpty)
  }

  @Test func atNowTakesAManifestLikeTheOtherSide() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let (a, _) = try Self.store(in: f)
    let exec = VMManifestHandlerTests.scripted(ManifestTests.macOutput, in: f)
    let result = try await Self.diff(a.id, "@now", in: f)
    let command = try #require(exec.commands.withLock { $0.first })
    #expect(command.hasSuffix(#"vmlab-manifest 'macos' '/opt'"#))
    let to = try #require(result.value["to"]?.stringValue)
    #expect(GuestManifest.isValidID(to) && to != a.id)
    #expect(result.value["users"]?["added"]?.numberValue ?? 0 >= 1)
  }

  @Test func sectionsAreCappedAndTheWholeDiffIsSaved() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let id = try f.context.store.find("web").id
    let a = GuestManifest(id: "m-0000000000c1", vm: id, profile: .linux)
    var b = GuestManifest(id: "m-0000000000c2", vm: id, profile: .linux)
    for n in 0..<600 { b.packages["pkg\(n)"] = "1.0" }
    try f.context.store.saveManifest(a)
    try f.context.store.saveManifest(b)
    let result = try await Self.diff(a.id, b.id, in: f)
    #expect(result.value["packages"]?["entries"]?.arrayValue?.count == 500)
    #expect(result.value["packages"]?["truncated"] == .bool(true))
    #expect(result.value["packages"]?["added"] == .number(600))
    let path = try #require(result.value["path"]?.stringValue)
    let saved = try JSONDecoder().decode(
      ManifestDiff.self, from: Data(contentsOf: URL(filePath: path)))
    #expect(saved.packages.count == 600)
  }

  @Test func aCheckpointNameResolvesToItsManifest() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let (a, b) = try Self.store(in: f)
    let pathA = f.context.store.manifestURL(of: a.vm, id: a.id).path
    let result = try await Self.diff("base", b.id, in: f) { name in
      name == "base" ? (name, pathA) : name == "bare" ? (name, nil) : nil
    }
    #expect(result.value["from"] == .string(a.id))
    let error = await #expect(throws: VMLabError.self) {
      try await Self.diff(b.id, "bare", in: f) { name in name == "bare" ? (name, nil) : nil }
    }
    #expect(error?.code == .invalidRequest && error?.data["field"] == .string("to"))
    #expect(error?.message.contains("has no manifest") == true)
  }

  @Test func badSidesAreInvalidRequest() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let (a, _) = try Self.store(in: f)
    let cases: [(String, String, String)] = [
      ("nothing", a.id, "from"), (a.id, "m-ffffffffffff", "to"), ("@now", "@now", "to"),
      ("", a.id, "from"),
    ]
    for (from, to, field) in cases {
      let error = await #expect(throws: VMLabError.self) { try await Self.diff(from, to, in: f) }
      #expect(error?.code == .invalidRequest, "\(from) \(to)")
      #expect(error?.data["field"] == .string(field), "\(from) \(to)")
    }
  }

  /// Through `vm_checkpoint`: a checkpoint created with `manifest: true` while the guest runs
  /// has a manifest, and diff against `@now` resolves it by name and by `@latest`.
  @Test func throughTheCheckpointTool() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    _ = VMManifestHandlerTests.scripted(ManifestTests.linuxOutput, in: f)
    func call(_ arguments: [String: JSONValue]) async throws(VMLabError) -> ToolResult {
      var arguments = arguments
      arguments["vm"] = .string("web")
      return try await ToolHandlers.call(
        "vm_checkpoint", arguments: .object(arguments), context: f.context)
    }
    let made = try await call([
      "action": .string("create"), "name": .string("A"), "manifest": .bool(true),
    ])
    let path = try #require(made.value["checkpoint"]?["manifestPath"]?.stringValue, "\(made)")
    let manifest = try f.context.store.loadManifest(at: URL(filePath: path))
    #expect(manifest.checkpoint == made.value["checkpoint"]?["id"]?.stringValue)
    for side in ["A", "@latest"] {
      let diff = try await call([
        "action": .string("diff"), "from": .string(side), "to": .string("@now"),
      ])
      #expect(diff.value["from"] == .string(manifest.id))
      #expect(diff.value["packages"]?["entries"]?.arrayValue?.isEmpty == true)
    }
    let none = try await call(["action": .string("create"), "name": .string("B")])
    #expect(none.value["checkpoint"]?["manifestPath"] == nil)
    let error = await #expect(throws: VMLabError.self) {
      try await call(["action": .string("diff"), "from": .string("B"), "to": .string("@now")])
    }
    #expect(error?.code == .invalidRequest && error?.data["field"] == .string("from"))
  }
}
