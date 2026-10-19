import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// `vm_serial` against the fake backend, whose `attach` hands out a channel connected to a fake
/// guest socket.
@Suite struct VMSerialHandlerTests {
  struct Fixture {
    let base: VMCreateHandlerTests.Fixture
    let guest: FakeSerialServer
    let channel: SerialChannel
    let vm: String

    init() async throws {
      base = try VMCreateHandlerTests.Fixture()
      guest = try FakeSerialServer()
      channel = SerialChannel(socketPath: guest.path, logURL: guest.logURL)
      try await channel.start()
      await guest.accept()
      base.backend.useSerial(channel)
      let created = try await base.create()
      vm = created.value["vm"]?["id"]?.stringValue ?? ""
    }

    func call(_ arguments: [String: JSONValue]) async throws(VMLabError) -> ToolResult {
      var arguments = arguments
      arguments["vm"] = .string(vm)
      return try await ToolHandlers.call(
        "vm_serial", arguments: .object(arguments), context: base.context)
    }

    func cleanUp() async {
      await channel.stop()
      guest.cleanUp()
      base.cleanUp()
    }
  }

  @Test func readTailAndOffsets() async throws {
    let f = try await Fixture()
    await guest(f, "line one\nline two\nline three\n")
    #expect(await eventually { await f.channel.endOffset == 29 })
    let all = try await f.call(["action": .string("read")])
    #expect(all.value["text"] == .string("line one\nline two\nline three\n"))
    #expect(all.value["offset"] == .number(29))
    #expect(all.value["truncated"] == .bool(false))
    let later = try await f.call(["action": .string("read"), "since": .number(9)])
    #expect(later.value["text"] == .string("line two\nline three\n"))
    let tail = try await f.call(["action": .string("tail"), "lines": .number(1)])
    #expect(tail.value["text"] == .string("line three\n"))
    await f.cleanUp()
  }

  /// `wait` starts at the beginning of the buffer by default, so a prompt printed before the call
  /// still matches; `since` the returned offset waits only for new output.
  @Test func waitDefaultsToTheStartAndReturnsTheOffsetAfterTheMatch() async throws {
    let f = try await Fixture()
    await guest(f, "boot...\ndebian login: ")
    #expect(await eventually { await f.channel.endOffset == 22 })
    let first = try await f.call(["action": .string("wait"), "pattern": .string("login: ")])
    #expect(first.value["matched"] == .string("login: "))
    #expect(first.value["offset"] == .number(22))
    #expect(first.value["text"] == .string("boot...\ndebian login: "))
    let reply = Task {
      try await f.call([
        "action": .string("wait"), "pattern": .string("Password:"), "since": .number(22),
      ])
    }
    let wrote = try await f.call(["action": .string("write"), "text": .string("root\n")])
    #expect(wrote.value["offset"] == .number(22))
    #expect(await f.guest.receive(5) == "root\n")
    await guest(f, "root\nPassword: ")
    let second = try await reply.value
    #expect(second.value["text"] == .string("root\nPassword:"))
    #expect(second.value["offset"] == .number(36))
    await f.cleanUp()
  }

  @Test func waitTimesOut() async throws {
    let f = try await Fixture()
    await #expect {
      try await f.call([
        "action": .string("wait"), "pattern": .string("never"), "timeoutSeconds": .number(1),
      ])
    } throws: { ($0 as? VMLabError)?.code == .timeout }
    await f.cleanUp()
  }

  @Test func missingArgumentsAreInvalidRequests() async throws {
    let f = try await Fixture()
    for (arguments, field) in [
      (["action": .string("write")], "text"),
      (["action": .string("wait")], "pattern"),
      (["action": .string("peek")], "action"),
      (["action": .string("read"), "since": .number(-1)], "since"),
      (["action": .string("tail"), "lines": .number(0)], "lines"),
    ] as [([String: JSONValue], String)] {
      await #expect {
        try await f.call(arguments)
      } throws: { error in
        let error = error as? VMLabError
        return error?.code == .invalidRequest && error?.data["field"] == .string(field)
      }
    }
    await f.cleanUp()
  }

  private func guest(_ f: Fixture, _ text: String) async { await f.guest.send(text) }
}
