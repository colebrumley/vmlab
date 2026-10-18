import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_exec` against the fake backend, whose exec channel echoes the command.
@Suite struct VMExecHandlerTests {
  typealias Fixture = VMCreateHandlerTests.Fixture

  static func exec(_ arguments: [String: JSONValue], in f: Fixture) async throws(VMLabError)
    -> ToolResult
  {
    var arguments = arguments
    arguments["vm"] = arguments["vm"] ?? .string("web")
    return try await ToolHandlers.call(
      "vm_exec", arguments: .object(arguments), context: f.context)
  }

  @Test func runsThroughTheExecChannel() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let result = try await Self.exec(["command": .string("uname -a")], in: f)
    #expect(result.value["exitCode"] == .number(0))
    #expect(result.value["stdout"] == .string("uname -a\n"))
    #expect(result.value["stderr"] == .string(""))
    #expect(result.value["truncated"] == .bool(false))
    #expect(result.value["durationMs"]?.numberValue != nil)
    #expect(result.value["logPath"] == nil)
    #expect(result.value["vm"]?["name"] == .string("web"))
  }

  @Test func aStoppedVMIsWrongState() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["autostart": .bool(false)])
    let error = await #expect(throws: VMLabError.self) {
      try await Self.exec(["command": .string("true")], in: f)
    }
    #expect(error?.code == .wrongState)
  }

  @Test func viaAgentNeedsExecAgent() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let error = await #expect(throws: VMLabError.self) {
      try await Self.exec(["command": .string("true"), "via": .string("agent")], in: f)
    }
    // The fixture plan grants exec_agent on qemu-hvf, but no backend offers it before R-403.
    #expect(error?.code == .guestUnreachable || error?.code == .capabilityMissing)
  }

  @Test func malformedFieldsAreInvalidRequest() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let cases: [([String: JSONValue], String)] = [
      (["command": .string("")], "command"),
      (["command": .string("x"), "timeoutSeconds": .number(0)], "timeoutSeconds"),
      (["command": .string("x"), "via": .string("telnet")], "via"),
      (["command": .string("x"), "env": .object(["1BAD": .string("v")])], "env"),
      (["command": .string("x"), "env": .object(["OK": .number(1)])], "env.OK"),
      (["command": .string("x"), "user": .string("")], "user"),
    ]
    for (arguments, field) in cases {
      let error = await #expect(throws: VMLabError.self) { try await Self.exec(arguments, in: f) }
      #expect(error?.code == .invalidRequest)
      #expect(error?.data["field"] == .string(field), "\(arguments)")
    }
  }
}
