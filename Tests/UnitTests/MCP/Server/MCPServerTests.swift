import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

/// The MCP server spoken to as a client would: newline-delimited JSON-RPC over two pipes, against
/// a temporary `VMLAB_HOME` whose host facts come from the fixtures of `ToolHandlerTests`.
@Suite struct MCPServerTests {
  /// One running server and the client ends of its pipes.
  final class Session: @unchecked Sendable {
    let toServer = Pipe()
    let fromServer = Pipe()
    let inbox = Inbox()
    let context: ToolContext
    let server: Task<Void, any Error>
    let reader: Task<Void, Never>

    init(context: ToolContext? = nil) throws {
      let context = try context ?? ToolHandlerTests.context()
      self.context = context
      let input = toServer.fileHandleForReading.fileDescriptor
      let output = fromServer.fileHandleForWriting.fileDescriptor
      // The server uses the raw numbers, so it keeps their pipes alive until it returns: a
      // session dropped early must not leave it reading or writing numbers reused elsewhere.
      let pipes = (toServer, fromServer)
      server = Task {
        defer { withExtendedLifetime(pipes) {} }
        try await VMLabServer.run(context: context, input: input, output: output)
      }
      let handle = fromServer.fileHandleForReading
      let inbox = inbox
      reader = Task {
        for await line in Self.lines(of: handle) { await inbox.add(line) }
      }
    }

    /// The lines `handle` yields, read on a thread of its own: `FileHandle.bytes` does its
    /// blocking `read` on the cooperative pool, which starves the other tests of the suite.
    static func lines(of handle: FileHandle) -> AsyncStream<String> {
      AsyncStream { continuation in
        Thread.detachNewThread {
          var pending = Data()
          while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
              continuation.yield(
                String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
              pending = Data(pending[pending.index(after: newline)...])
            }
          }
          if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
          continuation.finish()
        }
      }
    }

    func send(_ message: JSONValue) throws {
      var object = message.objectValue ?? [:]
      object["jsonrpc"] = .string("2.0")
      let line = ToolRendering.json(.object(object)) + "\n"
      try toServer.fileHandleForWriting.write(contentsOf: Data(line.utf8))
    }

    /// Sends a request and waits for the response with its id.
    func request(_ id: Int, _ method: String, _ params: JSONValue? = nil) async throws -> JSONValue
    {
      var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method)]
      if let params { message["params"] = params }
      try send(.object(message))
      return try await inbox.response(id: id)
    }

    func initialize() async throws -> JSONValue {
      let response = try await request(
        1, "initialize",
        .object([
          "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
          "clientInfo": .object(["name": .string("tests"), "version": .string("1")]),
        ]))
      try send(.object(["method": .string("notifications/initialized")]))
      return response
    }

    /// A session a failed test never closed still ends its server (end of input).
    deinit { try? toServer.fileHandleForWriting.close() }

    func close() async {
      try? toServer.fileHandleForWriting.close()
      _ = await server.result
      try? fromServer.fileHandleForWriting.close()
      await reader.value
      try? FileManager.default.removeItem(at: context.home)
    }
  }

  /// Every line the server wrote, decoded.
  actor Inbox {
    private(set) var messages: [JSONValue] = []

    func add(_ line: String) {
      if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) {
        messages.append(value)
      }
    }

    func response(id: Int, timeout: Duration = .seconds(10)) async throws -> JSONValue {
      let deadline = ContinuousClock.now + timeout
      while ContinuousClock.now < deadline {
        if let match = messages.first(where: { $0["id"] == .number(Double(id)) }) { return match }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw CancellationError()
    }
  }

  static func call(_ name: String, _ arguments: JSONValue = .object([:])) -> JSONValue {
    .object(["name": .string(name), "arguments": arguments])
  }

  /// The result object in the first (text) content block of a `tools/call` response.
  static func resultObject(_ response: JSONValue) throws -> JSONValue {
    let text = try #require(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  @Test func initializeNamesTheServer() async throws {
    let session = try Session()
    let response = try await session.initialize()
    #expect(response["result"]?["serverInfo"]?["name"] == .string("vmlab"))
    #expect(response["result"]?["serverInfo"]?["version"] == .string(VMLabMCP.version))
    #expect(response["result"]?["capabilities"]?["tools"] != nil)
    let ping = try await session.request(2, "ping")
    #expect(ping["result"] == .object([:]))
    await session.close()
  }

  @Test func toolsListOffersEveryBuiltTool() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let response = try await session.request(2, "tools/list")
    let tools = try #require(response["result"]?["tools"]?.arrayValue)
    #expect(tools.compactMap { $0["name"]?.stringValue } == ToolHandlers.specs.map(\.name))
    #expect(!tools.isEmpty)
    for (tool, spec) in zip(tools, ToolHandlers.specs) {
      #expect(tool["description"] == .string(spec.description))
      #expect(tool["inputSchema"] == spec.inputSchema)
    }
    await session.close()
  }

  @Test func hostFactsReturnsFacts() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let response = try await session.request(2, "tools/call", Self.call("host_facts"))
    #expect(response["result"]?["isError"] == .bool(false))
    let facts = try Self.resultObject(response)
    #expect(facts["chip"]?["model"] == .string("Apple M1 Max"))
    #expect(facts["qemu"]?["present"] == .bool(true))
    #expect(facts["warnings"] == .array([]))
    await session.close()
  }

  @Test func unknownToolIsAJSONRPCError() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let response = try await session.request(2, "tools/call", Self.call("no_such_tool"))
    #expect(response["result"] == nil)
    #expect(response["error"]?["code"] == .number(-32602))
    #expect(response["error"]?["message"]?.stringValue?.contains("no_such_tool") == true)
    await session.close()
  }

  @Test func refusalIsAnErrorResultWithTheAppendixDObject() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let missing = try await session.request(
      2, "tools/call", Self.call("vm_inspect", .object(["vm": .string("vm-nope00")])))
    #expect(missing["result"]?["isError"] == .bool(true))
    let error = try Self.resultObject(missing)
    #expect(error["code"] == .string("vm_not_found"))
    #expect(error["hint"]?.stringValue?.isEmpty == false)
    #expect(error["data"]?["vm"] == .string("vm-nope00"))
    let badField = try await session.request(
      3, "tools/call", Self.call("host_facts", .object(["x": .number(1)])))
    #expect(try Self.resultObject(badField)["code"] == .string("invalid_request"))
    await session.close()
  }

  @Test func callWithAProgressTokenStillAnswers() async throws {
    let session = try Session()
    _ = try await session.initialize()
    let response = try await session.request(
      2, "tools/call",
      .object([
        "name": .string("vm_list"), "arguments": .object([:]),
        "_meta": .object(["progressToken": .string("t-1")]),
      ]))
    #expect(try Self.resultObject(response)["vms"] == .array([]))
    await session.close()
  }

  /// R-205: `notifications/cancelled` cancels the slow `vm_create` it names; the VM directory is
  /// gone and no response is sent for that request, while progress arrived before it.
  @Test func cancelledCreateLeavesNoVMDirectoryAndNoResponse() async throws {
    let f = try VMCreateHandlerTests.Fixture()
    f.backend.delayCreate(.seconds(30))
    let session = try Session(context: f.context)
    _ = try await session.initialize()
    try session.send(
      .object([
        "id": .number(2), "method": .string("tools/call"),
        "params": .object([
          "name": .string("vm_create"),
          "arguments": .object([
            "requirements": VMCreateHandlerTests.Fixture.requirements,
            "allowUnverified": .bool(true), "autostart": .bool(false),
          ]),
          "_meta": .object(["progressToken": .string("create-1")]),
        ]),
      ]))
    let deadline = ContinuousClock.now + .seconds(10)
    while f.backend.operations.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(f.vmDirectories().count == 1)
    try session.send(
      .object([
        "method": .string("notifications/cancelled"),
        "params": .object(["requestId": .number(2), "reason": .string("test")]),
      ]))
    while !f.vmDirectories().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(f.vmDirectories().isEmpty)
    #expect(f.backend.operations == [.create, .destroy])
    // A later request is answered; the cancelled one never is.
    _ = try await session.request(3, "tools/call", Self.call("vm_list"))
    let messages = await session.inbox.messages
    #expect(!messages.contains { $0["id"] == .number(2) })
    let progress = messages.filter { $0["method"] == .string("notifications/progress") }
    #expect(progress.contains { $0["params"]?["progressToken"] == .string("create-1") })
    await session.close()
  }

  @Test func resultsBecomeTextThenImageBlocks() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let result = ToolResult(
      ["ok": .bool(true)], images: [ToolImage(data: png, mimeType: "image/png")])
    let encoded = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(VMLabServer.callResult(result)))
    let content = try #require(encoded["content"]?.arrayValue)
    #expect(content.count == 2)
    #expect(content[0]["type"] == .string("text"))
    #expect(content[0]["text"] == .string(result.text))
    #expect(content[1]["type"] == .string("image"))
    #expect(content[1]["mimeType"] == .string("image/png"))
    #expect(content[1]["data"] == .string(png.base64EncodedString()))
  }

  @Test func valuesRoundTripBetweenCoreAndTheSDK() {
    let json: JSONValue = .object([
      "n": .number(1), "f": .number(1.5), "s": .string("data:x"), "b": .bool(true), "z": .null,
      "a": .array([.number(-3)]),
    ])
    #expect(VMLabServer.jsonValue(VMLabServer.value(json)) == json)
  }

  @Test func progressReporterSendsOnlyWhenSet() async {
    #expect(!ToolProgress.none.isReporting)
    await ToolProgress.none.report(1)
    let seen = Seen()
    let progress = ToolProgress { progress, total, message in
      await seen.add("\(progress)/\(total ?? -1) \(message ?? "")")
    }
    #expect(progress.isReporting)
    await progress.report(1, total: 4, message: "pulling")
    #expect(await seen.items == ["1.0/4.0 pulling"])
  }

  actor Seen {
    var items: [String] = []
    func add(_ item: String) { items.append(item) }
  }
}

/// R-402: a server on its way out ends its background-job readers (the jobs keep running).
@Suite struct ServeShutdownTests {
  @Test func serveStopsJobReadersWhenStdinCloses() async throws {
    let f = try SSHExecTests.Fixture()
    let jobs = ExecJobs()
    let job = try await jobs.start(ExecRequest(command: "echo up; sleep 300"), on: f.channel)
    _ = try await jobs.read(job.id, on: f.channel)  // starts this process's reader
    #expect(await jobs.readerCount == 1)
    let toServer = Pipe()
    let fromServer = Pipe()
    let context = try ToolHandlerTests.context()
    let input = toServer.fileHandleForReading.fileDescriptor
    let output = fromServer.fileHandleForWriting.fileDescriptor
    let server = Task {
      try await VMLabServer.run(context: context, input: input, output: output, jobs: jobs)
    }
    try toServer.fileHandleForWriting.close()  // end of input: the server shuts down
    try await server.value
    #expect(await jobs.readerCount == 0)
    _ = try? await jobs.kill(job.id, on: f.channel)
  }
}
