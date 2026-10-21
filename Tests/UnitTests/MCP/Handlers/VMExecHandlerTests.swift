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

  /// R-403: `via: agent` goes to the VM's agent channel (the fixture plan grants exec_agent on
  /// qemu-hvf), `auto` to SSH when it was granted.
  @Test func viaPicksTheChannel() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let agent = try await Self.exec(["command": .string("id"), "via": .string("agent")], in: f)
    #expect(agent.value["stdout"] == .string("agent: id\n"))
    let auto = try await Self.exec(["command": .string("id")], in: f)
    #expect(auto.value["stdout"] == .string("id\n"))
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

  @Test func backgroundNeedsAnSSHChannel() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    // The fake backend's exec channel is not SSH.
    let error = await #expect(throws: VMLabError.self) {
      try await Self.exec(["command": .string("sleep 1"), "background": .bool(true)], in: f)
    }
    #expect(error?.code == .guestUnreachable)
    let stdin = await #expect(throws: VMLabError.self) {
      try await Self.exec(
        ["command": .string("cat"), "background": .bool(true), "stdin": .string("x")], in: f)
    }
    #expect(stdin?.data["field"] == .string("stdin"))
  }

  @Test func vmJobChecksItsArguments() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create()
    let cases: [([String: JSONValue], String)] = [
      (["job": .string("../x"), "action": .string("read")], "job"),
      (["job": .string("j-0123456789ab"), "action": .string("tail")], "action"),
      (
        [
          "job": .string("j-0123456789ab"), "action": .string("wait"), "timeoutSeconds": .number(0),
        ],
        "timeoutSeconds"
      ),
    ]
    for (arguments, field) in cases {
      var arguments = arguments
      arguments["vm"] = .string("web")
      let error = await #expect(throws: VMLabError.self) {
        try await ToolHandlers.call("vm_job", arguments: .object(arguments), context: f.context)
      }
      #expect(error?.data["field"] == .string(field))
    }
  }

  /// R-1202: a bare machine runs no guest OS, so every exec channel, `vm_file` and `vm_job` are
  /// `capability_missing`.
  @Test func aBareMachineHasNoExec() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["requirements": try VMCreateHandlerTests.bare("kernel")])
    for via in ["auto", "ssh", "agent"] {
      let error = await #expect(throws: VMLabError.self) {
        try await Self.exec(["command": .string("true"), "via": .string(via)], in: f)
      }
      #expect(error?.code == .capabilityMissing)
    }
    let background = await #expect(throws: VMLabError.self) {
      try await Self.exec(["command": .string("true"), "background": .bool(true)], in: f)
    }
    #expect(background?.code == .capabilityMissing)
    let file = await #expect(throws: VMLabError.self) {
      try await ToolHandlers.call(
        "vm_file",
        arguments: .object([
          "vm": .string("web"), "action": .string("pull"), "remote": .string("/etc/hostname"),
        ]), context: f.context)
    }
    #expect(file?.code == .capabilityMissing)
    let job = await #expect(throws: VMLabError.self) {
      try await ToolHandlers.call(
        "vm_job",
        arguments: .object([
          "vm": .string("web"), "job": .string("j-0123456789ab"), "action": .string("read"),
        ]), context: f.context)
    }
    #expect(job?.code == .capabilityMissing)
  }
}
