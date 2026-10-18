import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_checkpoint` through `VMManager` and the fake backend (R-800).
@Suite struct VMCheckpointHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  static func call(_ arguments: [String: JSONValue], in f: Fixture) async throws(VMLabError)
    -> ToolResult
  {
    var arguments = arguments
    arguments["vm"] = .string("web")
    return try await ToolHandlers.call(
      "vm_checkpoint", arguments: .object(arguments), context: f.context)
  }

  @Test func createListRestoreDelete() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    let a = try await Self.call(
      ["action": .string("create"), "name": .string("A"), "note": .string("n")], in: f)
    #expect(a.value["checkpoint"]?["name"] == .string("A"))
    #expect(a.value["checkpoint"]?["mode"] == .string("disk"))
    #expect(a.value["checkpoint"]?["note"] == .string("n"))
    #expect(a.value["vm"]?["name"] == .string("web"))
    let b = try await Self.call(
      ["action": .string("create"), "name": .string("B"), "manifest": .bool(true)], in: f)
    #expect(b.value["checkpoint"]?["parent"] == a.value["checkpoint"]?["id"])
    #expect(b.value["checkpoint"]?["manifestPath"] == nil)
    // The guest is not running, so the manifest cannot be taken: a warning, not a failure.
    #expect(b.warnings.contains { $0.contains("without a manifest") })

    let list = try await Self.call(["action": .string("list")], in: f)
    #expect(list.value["nodes"]?.arrayValue?.count == 2)
    #expect(list.value["current"] == b.value["checkpoint"]?["id"])

    let restored = try await Self.call(
      ["action": .string("restore"), "name": .string("@latest")], in: f)
    #expect(restored.value["checkpoint"]?["name"] == .string("B"))
    #expect(restored.value["state"] == .string("created"))

    let refused = await #expect(throws: VMLabError.self) {
      try await Self.call(["action": .string("delete"), "name": .string("A")], in: f)
    }
    #expect(refused?.code == .invalidRequest)
    let deleted = try await Self.call(
      ["action": .string("delete"), "name": .string("A"), "recursive": .bool(true)], in: f)
    #expect(deleted.value["deleted"] == .array([.string("B"), .string("A")]))
  }

  @Test func refusals() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    for arguments: [String: JSONValue] in [
      ["action": .string("create")],
      ["action": .string("create"), "name": .string("A"), "mode": .string("hot")],
      ["action": .string("diff"), "from": .string("A"), "to": .string("@now")],
      ["action": .string("rewind")],
    ] {
      let error = await #expect(throws: VMLabError.self) { try await Self.call(arguments, in: f) }
      #expect(error?.code == .invalidRequest)
    }
  }
}
