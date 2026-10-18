import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_introspect` and `vm_memory_dump` through `VMManager.attach` and the fake backend.
@Suite struct VMIntrospectHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  static func create(in f: Fixture, require: [String]) async throws {
    var requirements = Fixture.requirements.objectValue ?? [:]
    requirements["require"] = .array(require.map { .string($0) })
    _ = try await f.create(["requirements": .object(requirements)])
  }

  static func call(_ tool: String, _ arguments: [String: JSONValue], in f: Fixture)
    async throws(VMLabError) -> ToolResult
  {
    var arguments = arguments
    arguments["vm"] = arguments["vm"] ?? .string("web")
    return try await ToolHandlers.call(tool, arguments: .object(arguments), context: f.context)
  }

  @Test func answersJSONOrText() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await Self.create(in: f, require: ["serial", "introspection"])
    let pci = try await Self.call("vm_introspect", ["query": .string("pci")], in: f)
    #expect(pci.value["query"] == .string("pci"))
    #expect(pci.value["json"]?["query"] == .string("pci"))
    let mtree = try await Self.call("vm_introspect", ["query": .string("memory_tree")], in: f)
    #expect(mtree.value["text"] == .string("fake memory_tree"))
    #expect(mtree.value["json"] == nil)
    let raw = try await Self.call(
      "vm_introspect", ["query": .string("raw"), "hmp": .string("info mtree")], in: f)
    #expect(raw.value["query"] == .string("raw"))
    #expect(raw.value["text"] == .string("fake raw"))
  }

  @Test(arguments: [
    ["query": JSONValue.string("raw")],
    ["query": .string("raw"), "qmp": .string("query-pci"), "hmp": .string("info pci")],
    ["query": .string("pci"), "qmp": .string("query-pci")],
    ["query": .string("bogus")],
  ])
  func malformedQueriesAreInvalidRequests(arguments: [String: JSONValue]) async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await Self.create(in: f, require: ["serial", "introspection"])
    let error = await #expect(throws: VMLabError.self) {
      try await Self.call("vm_introspect", arguments, in: f)
    }
    #expect(error?.code == .invalidRequest)
  }

  /// (A plan without the feature is `capability_missing`: `BackendTests` covers the channels.)
  @Test func needsARunningGuest() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await Self.create(in: f, require: ["serial", "introspection"])
    _ = try await ToolHandlers.call(
      "vm_lifecycle", arguments: .object(["vm": .string("web"), "action": .string("stop")]),
      context: f.context)
    let stopped = await #expect(throws: VMLabError.self) {
      try await Self.call("vm_introspect", ["query": .string("status")], in: f)
    }
    #expect(stopped?.code == .wrongState)
  }

  @Test func memoryDumpWritesUnderDumps() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await Self.create(in: f, require: ["serial", "memory_dump"])
    let range = try await Self.call(
      "vm_memory_dump", ["address": .string("0x40000000"), "size": .number(1_048_576)], in: f)
    let path = try #require(range.value["path"]?.stringValue)
    let id = try f.context.store.find("web").id
    #expect(path.hasPrefix(f.context.store.directory(of: id).appending(path: "dumps/").path))
    #expect(path.hasSuffix("-0x40000000-1048576.raw"))
    #expect(range.value["bytes"] == .number(1_048_576))
    #expect(range.value["format"] == .string("raw"))
    #expect(FileManager.default.fileExists(atPath: path))
    let all = try await Self.call("vm_memory_dump", [:], in: f)
    #expect(all.value["format"] == .string("elf"))
    #expect(all.value["path"]?.stringValue?.hasSuffix(".elf") == true)
  }

  @Test func bigRangesNeedConfirm() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await Self.create(in: f, require: ["serial", "memory_dump"])
    let big: [String: JSONValue] = [
      "address": .string("0x40000000"), "size": .number(Double((256 << 20) + 1)),
    ]
    let error = await #expect(throws: VMLabError.self) {
      try await Self.call("vm_memory_dump", big, in: f)
    }
    #expect(error?.code == .confirmRequired)
    #expect(error?.data["bytes"] == .number(Double((256 << 20) + 1)))
    // Exactly 256 MB needs none.
    _ = try await Self.call(
      "vm_memory_dump", ["address": .string("0x0"), "size": .number(Double(256 << 20))], in: f)
  }

  @Test(arguments: [
    ["address": JSONValue.string("0x1000")], ["size": .number(16)],
    ["address": .string("4096"), "size": .number(16)],
    ["address": .string("0xzz"), "size": .number(16)],
    ["address": .string("0x0"), "size": .number(0)],
  ])
  func malformedRangesAreInvalidRequests(arguments: [String: JSONValue]) async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try await Self.create(in: f, require: ["serial", "memory_dump"])
    let error = await #expect(throws: VMLabError.self) {
      try await Self.call("vm_memory_dump", arguments, in: f)
    }
    #expect(error?.code == .invalidRequest)
  }
}
