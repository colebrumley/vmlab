import Darwin
import Foundation
import Synchronization
import Testing
import VMLabCore

/// R-1100: two `vmlab serve` processes (two Claude sessions) on one `VMLAB_HOME`. Both create and
/// start a `qemu-hvf` Debian guest at the same moment, then race to create a VM under one name;
/// every record must load, the names stay unique, and both servers list the same VMs.
@Suite(.enabled(if: integrationEnabled), .serialized)
struct TwoServersIntegrationTests {
  /// The `vmlab` built next to this test bundle.
  static func vmlabURL() throws -> URL {
    let dir = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
    let url = dir.appending(path: "vmlab")
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "no \(url.path)")
    return url
  }

  static func requirements(memoryGB: Int = 1) -> JSONValue {
    [
      "guest": ["os": "linux", "arch": "arm64"],
      // introspection keeps both on QEMU (hvf ranks first); no exec_ssh, so no SSH wait.
      "require": ["serial", "introspection"],
      "resources": ["cpus": 1, "memoryGB": .number(Double(memoryGB)), "diskGB": 8],
      "image": "debian-13-arm64",
    ]
  }

  @Test func twoServersCreateAtOnce() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-2s")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab/images"))
    let binary = try Self.vmlabURL()
    let a = try StdioMCPClient(binary: binary, home: home, tag: "a")
    let b = try StdioMCPClient(binary: binary, home: home, tag: "b")
    var created: [(StdioMCPClient, String)] = []
    defer {
      a.terminate()
      b.terminate()
      // Anything a failed run left behind: the guests' QEMU processes and the home.
      for pid in Self.qemuPIDs(in: home) { kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: home)
    }
    try await a.initialize()
    try await b.initialize()

    // Both at once.
    async let first = a.call(
      "vm_create", ["requirements": Self.requirements(), "name": "alpha", "autostart": true])
    async let second = b.call(
      "vm_create", ["requirements": Self.requirements(), "name": "beta", "autostart": true])
    let (one, two) = try await (first, second)
    #expect(one.isError == false, "\(one.text)")
    #expect(two.isError == false, "\(two.text)")
    let alpha = one.value["vm"]?["id"]?.stringValue
    let beta = two.value["vm"]?["id"]?.stringValue
    if let alpha { created.append((a, alpha)) }
    if let beta { created.append((b, beta)) }
    #expect(one.value["plan"]?["profile"] == "qemu-hvf")
    #expect(one.value["state"] == "running" && two.value["state"] == "running")
    #expect(alpha != nil && alpha != beta)

    // A race for one name: the store lock lets exactly one win.
    async let dupA = a.call(
      "vm_create", ["requirements": Self.requirements(), "name": "dup", "autostart": false])
    async let dupB = b.call(
      "vm_create", ["requirements": Self.requirements(), "name": "dup", "autostart": false])
    let dups = try await [dupA, dupB]
    #expect(dups.filter { !$0.isError }.count == 1, "\(dups.map(\.text))")
    #expect(dups.filter(\.isError).first?.value["code"] == "invalid_request")
    for (client, result) in zip([a, b], dups) where !result.isError {
      if let id = result.value["vm"]?["id"]?.stringValue { created.append((client, id)) }
    }

    // No corruption: every record loads, and both servers see the same three VMs.
    let store = Store(home: home)
    let listing = try store.list()
    #expect(listing.unreadable.isEmpty)
    #expect(Set(listing.records.map(\.name)) == ["alpha", "beta", "dup"])
    let running = listing.records.filter { $0.state == .running }
    #expect(running.count == 2)
    #expect(Set(running.compactMap(\.runtime?.pid)).count == 2)
    for client in [a, b] {
      let rows = try await client.call("vm_list", [:]).value["vms"]?.arrayValue ?? []
      #expect(Set(rows.compactMap { $0["name"]?.stringValue }) == ["alpha", "beta", "dup"])
    }

    // Each server destroys what it made (QEMU's QMP serves one client: the one that started it).
    for (client, id) in created {
      let result = try await client.call("vm_lifecycle", ["vm": .string(id), "action": "destroy"])
      #expect(result.isError == false, "\(result.text)")
    }
    #expect(try store.list().records.isEmpty)
  }

  /// QEMU's QMP serves one client per monitor: server A holds `qmp.sock` of the guest it
  /// started, and server B reaches the same guest through `qmp2.sock`.
  @Test func secondServerUsesQMPOnTheFirstServersGuest() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-qm")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab/images"))
    let binary = try Self.vmlabURL()
    let a = try StdioMCPClient(binary: binary, home: home, tag: "a")
    let b = try StdioMCPClient(binary: binary, home: home, tag: "b")
    defer {
      a.terminate()
      b.terminate()
      for pid in Self.qemuPIDs(in: home) { kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: home)
    }
    try await a.initialize()
    try await b.initialize()
    let made = try await a.call(
      "vm_create", ["requirements": Self.requirements(), "name": "shared", "autostart": true])
    try #require(made.isError == false, "\(made.text)")
    // A holds the guest's first monitor (it started it, and its watchdog keeps it).
    let mine = try await a.call("vm_introspect", ["vm": "shared", "query": "status"])
    #expect(mine.isError == false, "\(mine.text)")
    let started = ContinuousClock.now
    let theirs = try await b.call("vm_introspect", ["vm": "shared", "query": "status"])
    #expect(theirs.isError == false, "\(theirs.text)")
    #expect(theirs.text.contains("running"), "\(theirs.text)")
    #expect(ContinuousClock.now - started < .seconds(20))
    // B can drive it too: pause and resume through its own monitor.
    for action in ["pause", "resume"] {
      let result = try await b.call("vm_lifecycle", ["vm": "shared", "action": .string(action)])
      #expect(result.isError == false, "\(result.text)")
    }
    let gone = try await a.call("vm_lifecycle", ["vm": "shared", "action": "destroy"])
    #expect(gone.isError == false, "\(gone.text)")
  }

  /// QEMU processes whose command line names a file under `home`.
  static func qemuPIDs(in home: URL) -> [Int32] {
    let vms = home.appending(path: "vms")
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: vms.path)) ?? []
    return ids.compactMap { id in
      let pidFile = vms.appending(path: "\(id)/qemu.pid")
      guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
      return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

private final class BundleToken {}

/// A minimal MCP client over a child `vmlab serve`'s stdio: newline-delimited JSON-RPC.
final class StdioMCPClient: Sendable {
  struct Result: Sendable {
    var isError: Bool
    var text: String
    var value: JSONValue
    /// How many image blocks followed the text (vm_computer).
    var images: Int = 0
  }

  let process: Process
  private let input: FileHandle
  private final class State: Sendable {
    let value = Mutex<(next: Int, pending: [Int: CheckedContinuation<JSONValue, any Error>])>(
      (1, [:]))
  }
  private let box = State()

  /// `stderr`: a file for the server's log (default: discarded).
  init(binary: URL, home: URL, tag: String, stderr: URL? = nil) throws {
    process = Process()
    process.executableURL = binary
    process.arguments = ["serve"]
    var environment = ProcessInfo.processInfo.environment
    environment["VMLAB_HOME"] = home.path
    process.environment = environment
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    if let stderr { FileManager.default.createFile(atPath: stderr.path, contents: nil) }
    process.standardError =
      FileHandle(forWritingAtPath: stderr?.path ?? "/dev/null") ?? FileHandle.standardError
    input = stdin.fileHandleForWriting
    try process.run()
    let reader = stdout.fileHandleForReading
    let box = box
    Thread.detachNewThread {
      var buffer = Data()
      while true {
        let chunk = reader.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
          let line = buffer[buffer.startIndex..<newline]
          buffer = Data(buffer[buffer.index(after: newline)...])
          guard let message = try? JSONDecoder().decode(JSONValue.self, from: line),
            let id = message["id"]?.numberValue.map(Int.init)
          else { continue }
          let waiter = box.value.withLock { $0.pending.removeValue(forKey: id) }
          waiter?.resume(returning: message)
        }
      }
      let waiters = box.value.withLock { s -> [CheckedContinuation<JSONValue, any Error>] in
        defer { s.pending = [:] }
        return Array(s.pending.values)
      }
      for waiter in waiters {
        waiter.resume(
          throwing: VMLabError(code: .internal, message: "server \(tag) exited", hint: ""))
      }
    }
  }

  func send(_ message: JSONValue) throws {
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)
    try input.write(contentsOf: data)
  }

  func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      let id = box.value.withLock { s -> Int in
        defer { s.next += 1 }
        s.pending[s.next] = continuation
        return s.next
      }
      do {
        try send([
          "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method),
          "params": params,
        ])
      } catch {
        box.value.withLock { _ = $0.pending.removeValue(forKey: id) }
        continuation.resume(throwing: error)
      }
    }
  }

  func initialize() async throws {
    _ = try await request(
      "initialize",
      [
        "protocolVersion": "2025-03-26", "capabilities": [:],
        "clientInfo": ["name": "two-servers-test", "version": "1"],
      ])
    try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
  }

  /// `tools/call`: the result's text block parsed as JSON.
  func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> Result {
    let reply = try await request(
      "tools/call", ["name": .string(name), "arguments": .object(arguments)])
    let result = reply["result"] ?? .null
    let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "\(reply)"
    let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    let images = result["content"]?.arrayValue?.filter { $0["type"] == "image" }.count ?? 0
    return Result(
      isError: result["isError"] == .bool(true), text: text, value: value, images: images)
  }

  /// Closes stdin, sends SIGTERM, and waits at most 10 s before SIGKILL. Never blocks for good:
  /// `waitUntilExit()` hung a full integration run here once, after the child was already gone.
  func terminate() {
    try? input.close()
    guard process.processIdentifier > 0 else { return }
    if process.isRunning { process.terminate() }
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
}

// Literals for building JSON-RPC messages in this file.
extension JSONValue: ExpressibleByStringLiteral,
  ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}
