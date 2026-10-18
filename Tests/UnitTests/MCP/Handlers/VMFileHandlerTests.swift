import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_file` argument checks against the fake backend (whose exec channel is not SSH).
@Suite struct VMFileHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  static func file(_ arguments: [String: JSONValue], in f: Fixture) async throws(VMLabError)
    -> ToolResult
  {
    var arguments = arguments
    arguments["vm"] = arguments["vm"] ?? .string("web")
    return try await ToolHandlers.call(
      "vm_file", arguments: .object(arguments), context: f.context)
  }

  @Test func malformedFieldsAreInvalidRequest() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let cases: [([String: JSONValue], String)] = [
      (["action": .string("copy"), "remote": .string("/x")], "action"),
      (["action": .string("push"), "remote": .string("/x")], "local"),
      (["action": .string("pull"), "remote": .string("/x"), "local": .string("rel")], "local"),
      // R-1102: outside the user's home and /tmp (no allowAnyPath in the test home's config).
      (
        ["action": .string("push"), "remote": .string("/x"), "local": .string("/etc/passwd")],
        "local"
      ),
      (
        ["action": .string("pull"), "remote": .string("/x"), "local": .string("/tmp/../etc/x")],
        "local"
      ),
    ]
    for (arguments, field) in cases {
      let error = await #expect(throws: VMLabError.self) { try await Self.file(arguments, in: f) }
      #expect(error?.code == .invalidRequest)
      #expect(error?.data["field"] == .string(field), "\(arguments)")
    }
  }

  @Test func needsAnSSHChannel() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let error = await #expect(throws: VMLabError.self) {
      try await Self.file(["action": .string("pull"), "remote": .string("/etc/hostname")], in: f)
    }
    #expect(error?.code == .guestUnreachable)
  }
}
