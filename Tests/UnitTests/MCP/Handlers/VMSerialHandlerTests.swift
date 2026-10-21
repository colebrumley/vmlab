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

    /// Calls a handler with its own engine check and grace, as `call` does through the registry.
    func call(_ handler: VMSerialHandler, _ arguments: [String: JSONValue]) async throws(VMLabError)
      -> ToolResult
    {
      var arguments = arguments
      arguments["vm"] = .string(vm)
      return try await handler.call(
        try ToolArguments(.object(arguments), spec: .vmSerial), context: base.context)
    }

    var directory: URL { base.context.store.directory(of: vm) }

    /// Puts `text` in the VM's console log, as the engine would have.
    func console(_ text: String) throws {
      try Data(text.utf8).write(to: directory.appending(path: "console.log"))
    }

    /// Moves the record to `state` with no engine, as a power-off leaves it.
    func settle(_ state: VMState, features: [Feature]? = nil) throws {
      try base.context.store.update(id: vm) { record in
        record.state = state
        record.runtime = nil
        if let features { record.features = features }
      }
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

  /// The console log spans every run of the VM: without `since`, read and wait start where the
  /// last start began (`<vm>/console.start`), so an old run's prompt does not match.
  @Test func readAndWaitDefaultToTheCurrentRun() async throws {
    let f = try await Fixture()
    await guest(f, "old login: \nnew boot\n")
    #expect(await eventually { await f.channel.endOffset == 21 })
    let directory = f.base.context.store.directory(of: f.vm)
    try Data("12\n".utf8).write(to: directory.appending(path: "console.start"))
    let read = try await f.call(["action": .string("read")])
    #expect(read.value["text"] == .string("new boot\n"))
    let waiting = Task {
      try await f.call(["action": .string("wait"), "pattern": .string("login: ")])
    }
    await guest(f, "debian login: ")
    let match = try await waiting.value
    #expect(match.value["offset"] == .number(35))
    let all = try await f.call(["action": .string("read"), "since": .number(0)])
    #expect(all.value["text"]?.stringValue?.hasPrefix("old login: ") == true)
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

  // MARK: A guest that is not running (R-1201)

  @Test func readTailAndWaitAnswerFromTheLogOfAStoppedGuest() async throws {
    let f = try await Fixture()
    try f.console("old run\nboot ok\nSYSTEM_OFF\n")
    try Data("8\n".utf8).write(to: f.directory.appending(path: "console.start"))
    try f.settle(.stopped)
    let read = try await f.call(["action": .string("read")])
    #expect(read.value["text"] == .string("boot ok\nSYSTEM_OFF\n"))
    #expect(read.value["offset"] == .number(27))
    #expect(read.value["truncated"] == .bool(false))
    let all = try await f.call(["action": .string("read"), "since": .number(0)])
    #expect(all.value["text"] == .string("old run\nboot ok\nSYSTEM_OFF\n"))
    let tail = try await f.call(["action": .string("tail"), "lines": .number(1)])
    #expect(tail.value["text"] == .string("SYSTEM_OFF\n"))
    #expect(tail.value["offset"] == .number(27))
    let match = try await f.call(["action": .string("wait"), "pattern": .string("boot o.")])
    #expect(match.value["matched"] == .string("boot ok"))
    #expect(match.value["offset"] == .number(15))
    #expect(match.value["text"] == .string("boot ok"))
    #expect(match.value["stopped"] == nil)
    // The default start is this run's: the old run's text does not match.
    let clock = ContinuousClock()
    let started = clock.now
    let none = try await f.call([
      "action": .string("wait"), "pattern": .string("old run"), "timeoutSeconds": .number(30),
    ])
    #expect(clock.now - started < .seconds(5))
    #expect(none.value["stopped"] == .bool(true))
    #expect(none.value["matched"] == nil)
    #expect(none.value["text"] == .string("boot ok\nSYSTEM_OFF\n"))
    #expect(none.value["offset"] == .number(27))
    #expect(none.value["truncated"] == .bool(false))
    await f.cleanUp()
  }

  /// A long log: the no-match text is capped as a timed-out wait's is.
  @Test func aStoppedWaitCapsItsText() async throws {
    let f = try await Fixture()
    let line = String(repeating: "x", count: 99) + "\n"
    try f.console(String(repeating: line, count: 100))
    try f.settle(.stopped)
    let none = try await f.call([
      "action": .string("wait"), "pattern": .string("never"), "since": .number(0),
    ])
    #expect(none.value["stopped"] == .bool(true))
    #expect(none.value["offset"] == .number(10_000))
    #expect(none.value["text"]?.stringValue?.utf8.count == Int(SerialChannel.timeoutTextBytes))
    #expect(none.value["truncated"] == .bool(true))
    await f.cleanUp()
  }

  @Test func everyStateThatIsNotLiveReadsTheLog() async throws {
    let f = try await Fixture()
    try f.console("hello\n")
    for state in [VMState.suspended, .created, .broken] {
      try f.settle(state)
      let read = try await f.call(["action": .string("read"), "since": .number(0)])
      #expect(read.value["text"] == .string("hello\n"), "\(state)")
    }
    await f.cleanUp()
  }

  @Test func aStoppedGuestWithNoLogHasPrintedNothing() async throws {
    let f = try await Fixture()
    try f.settle(.stopped)
    try? FileManager.default.removeItem(at: f.directory.appending(path: "console.log"))
    for action in ["read", "tail"] {
      let result = try await f.call(["action": .string(action)])
      #expect(result.value["text"] == .string(""))
      #expect(result.value["offset"] == .number(0))
      #expect(result.value["stopped"] == nil)
    }
    let wait = try await f.call(["action": .string("wait"), "pattern": .string("x")])
    #expect(wait.value["stopped"] == .bool(true))
    #expect(wait.value["text"] == .string(""))
    #expect(wait.value["offset"] == .number(0))
    #expect(
      !FileManager.default.fileExists(atPath: f.directory.appending(path: "console.log").path))
    await f.cleanUp()
  }

  @Test func writeToAStoppedGuestIsWrongState() async throws {
    let f = try await Fixture()
    try f.console("hello\n")
    try f.settle(.stopped)
    await #expect {
      try await f.call(["action": .string("write"), "text": .string("x\n")])
    } throws: { error in
      let error = error as? VMLabError
      return error?.code == .wrongState && error?.hint.contains("vm_lifecycle start") == true
    }
    await f.cleanUp()
  }

  @Test func aStoppedGuestPlannedWithoutSerialIsCapabilityMissing() async throws {
    let f = try await Fixture()
    try f.console("hello\n")
    try f.settle(.stopped, features: [.gdb])
    for action in ["read", "tail"] {
      await #expect {
        try await f.call(["action": .string(action)])
      } throws: { ($0 as? VMLabError)?.code == .capabilityMissing }
    }
    await #expect {
      try await f.call(["action": .string("wait"), "pattern": .string("x")])
    } throws: { ($0 as? VMLabError)?.code == .capabilityMissing }
    await f.cleanUp()
  }

  /// The guest powers off during a wait: the channel's reader ends with no match, the engine (the
  /// fake runtime's pid names no engine) is gone, so the wait is `stopped`, not unreachable.
  @Test func aWaitWhoseGuestPowersOffIsStopped() async throws {
    let f = try await Fixture()
    try f.console("boot ok\nSYSTEM_OFF\n")
    let clock = ContinuousClock()
    let waiting = Task {
      try await f.call([
        "action": .string("wait"), "pattern": .string("never"), "since": .number(0),
        "timeoutSeconds": .number(60),
      ])
    }
    await guest(f, "boot ok\nSYSTEM_OFF\n")
    #expect(await eventually { await f.channel.endOffset == 19 })
    let ended = clock.now
    f.guest.closePeer()
    let result = try await waiting.value
    #expect(clock.now - ended < .seconds(2))
    #expect(result.value["stopped"] == .bool(true))
    #expect(result.value["matched"] == nil)
    #expect(result.value["text"] == .string("boot ok\nSYSTEM_OFF\n"))
    #expect(result.value["offset"] == .number(19))
    await f.cleanUp()
  }

  /// The reader ended but the engine still runs after the grace: `guest_unreachable` as before.
  @Test func aWaitWhoseEngineStillRunsIsUnreachable() async throws {
    let f = try await Fixture()
    var handler = VMSerialHandler()
    handler.engineIsRunning = { _, _ in true }
    handler.exitGrace = .milliseconds(300)
    let waiting = Task {
      try await f.call(
        handler,
        ["action": .string("wait"), "pattern": .string("never"), "timeoutSeconds": .number(60)])
    }
    try await Task.sleep(for: .milliseconds(50))
    f.guest.closePeer()
    await #expect {
      try await waiting.value
    } throws: { ($0 as? VMLabError)?.code == .guestUnreachable }
    await f.cleanUp()
  }

  /// The engine exited ahead of the record, so attaching fails: with the engine gone, the log
  /// answers; with it still running, the attach error stands.
  @Test func aRunningRecordWhoseEngineExitedReadsTheLog() async throws {
    let f = try await Fixture()
    try f.console("SYSTEM_OFF\n")
    let gone = VMLabError(
      code: .guestUnreachable, message: "No QEMU process runs", hint: "Start the VM.")
    f.base.backend.fail(.attach, with: gone)
    let wait = try await f.call([
      "action": .string("wait"), "pattern": .string("never"), "since": .number(0),
    ])
    #expect(wait.value["stopped"] == .bool(true))
    #expect(wait.value["text"] == .string("SYSTEM_OFF\n"))
    var handler = VMSerialHandler()
    handler.engineIsRunning = { _, _ in true }
    f.base.backend.fail(.attach, with: gone)
    await #expect {
      try await f.call(handler, ["action": .string("read")])
    } throws: { ($0 as? VMLabError)?.message == "No QEMU process runs" }
    await f.cleanUp()
  }

  /// A match in output that arrived before the reader ended is a match, not `stopped`.
  @Test func aMatchBeforeThePowerOffIsAMatch() async throws {
    let f = try await Fixture()
    await guest(f, "tests passed\n")
    f.guest.closePeer()
    #expect(await eventually { await !f.channel.isConnected })
    let result = try await f.call([
      "action": .string("wait"), "pattern": .string("passed"), "since": .number(0),
    ])
    #expect(result.value["matched"] == .string("passed"))
    #expect(result.value["stopped"] == nil)
    await f.cleanUp()
  }

  private func guest(_ f: Fixture, _ text: String) async { await f.guest.send(text) }
}
