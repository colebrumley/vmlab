import Darwin
import Foundation
import Testing
import VMLabCore
import VMLabMCP
import VMLabVZ

/// R-1104 Verify: the five worked sessions of `docs/AGENT.md`, read from the document itself so
/// the guide and the test cannot drift. Every ```` ```json call ```` block is sent, in order, to a
/// real `vmlab serve` over its stdio, and the ```` ```json result ```` (or ```` ```json error ````)
/// block after it is the shape the answer must have. The matching rules are the guide's own
/// ("Reading the result blocks"): listed fields must be present and equal, extra fields are fine,
/// `<string>`-style placeholders match any value of that kind, `<~re>` matches a string the
/// regular expression finds something in, `<kind:name>` also captures the value, and `{{name}}`
/// in a later call or result is replaced by it.
enum AgentGuide {
  static let url = VZRunnerIntegrationTests.root.appending(path: "docs/AGENT.md")

  struct Step: Sendable {
    var line: Int
    var tool: String
    var arguments: JSONValue
    /// The result block, or the error block when `fails`.
    var expected: JSONValue?
    var fails = false
  }

  struct Session: Sendable {
    var number: Int
    var title: String
    var steps: [Step]
  }

  struct ParseError: Error, CustomStringConvertible {
    var description: String
  }

  static func load() throws -> [Session] {
    try sessions(String(contentsOf: url, encoding: .utf8))
  }

  /// The sessions under `### Session N: title` headings, each with its calls in order. A session
  /// ends at the next heading of level 2 or 3; fenced blocks outside sessions are ignored.
  static func sessions(_ text: String) throws -> [Session] {
    var sessions: [Session] = []
    var inSession = false
    var fence: (kind: String, line: Int, body: [String])?
    for (index, line) in text.components(separatedBy: "\n").enumerated() {
      let number = index + 1
      if var open = fence {
        if line.trimmingCharacters(in: .whitespaces) == "```" {
          fence = nil
          guard inSession, ["call", "result", "error"].contains(open.kind) else { continue }
          let body = open.body.joined(separator: "\n")
          guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
          else { throw ParseError(description: "AGENT.md:\(open.line): not JSON") }
          try add(open.kind, value, line: open.line, to: &sessions[sessions.count - 1])
        } else {
          open.body.append(line)
          fence = open
        }
        continue
      }
      if line.hasPrefix("```") {
        let info = line.dropFirst(3).split(separator: " ").map(String.init)
        fence = (info.count == 2 && info[0] == "json" ? info[1] : "other", number, [])
        continue
      }
      if line.hasPrefix("### Session ") {
        let rest = line.dropFirst("### Session ".count)
        guard let colon = rest.firstIndex(of: ":"), let n = Int(rest[..<colon]) else {
          throw ParseError(description: "AGENT.md:\(number): session heading without a number")
        }
        let title = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        sessions.append(Session(number: n, title: title, steps: []))
        inSession = true
      } else if line.hasPrefix("## ") || line.hasPrefix("### ") {
        inSession = false
      }
    }
    return sessions
  }

  private static func add(_ kind: String, _ value: JSONValue, line: Int, to session: inout Session)
    throws
  {
    if kind == "call" {
      guard let tool = value["tool"]?.stringValue else {
        throw ParseError(description: "AGENT.md:\(line): a call names no tool")
      }
      session.steps.append(
        Step(line: line, tool: tool, arguments: value["arguments"] ?? .object([:])))
      return
    }
    guard let last = session.steps.indices.last, session.steps[last].expected == nil else {
      throw ParseError(description: "AGENT.md:\(line): a \(kind) block follows no call")
    }
    session.steps[last].expected = value
    session.steps[last].fails = kind == "error"
  }

  // MARK: Substitution and matching

  /// `value` with every `{{name}}` replaced by the captured value: the value itself when the
  /// string is only the reference, else its text spliced in.
  static func substitute(_ value: JSONValue, _ vars: [String: JSONValue]) -> JSONValue {
    switch value {
    case .string(let string):
      if string.hasPrefix("{{"), string.hasSuffix("}}"),
        let whole = vars[String(string.dropFirst(2).dropLast(2))]
      {
        return whole
      }
      var out = string
      for (name, captured) in vars where out.contains("{{\(name)}}") {
        let text = captured.stringValue ?? ToolRendering.json(captured)
        out = out.replacingOccurrences(of: "{{\(name)}}", with: text)
      }
      return .string(out)
    case .array(let items): return .array(items.map { substitute($0, vars) })
    case .object(let object): return .object(object.mapValues { substitute($0, vars) })
    default: return value
    }
  }

  /// The names a value refers to with `{{name}}`.
  static func references(_ value: JSONValue) -> Set<String> {
    switch value {
    case .string(let string):
      var names: Set<String> = []
      var rest = Substring(string)
      while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
        names.insert(String(rest[open.upperBound..<close.lowerBound]))
        rest = rest[close.upperBound...]
      }
      return names
    case .array(let items): return items.reduce(into: []) { $0.formUnion(references($1)) }
    case .object(let object):
      return object.values.reduce(into: []) { $0.formUnion(references($1)) }
    default: return []
    }
  }

  /// The names a result block captures with `<kind:name>`.
  static func captures(_ value: JSONValue) -> Set<String> {
    switch value {
    case .string(let string):
      if let placeholder = Placeholder(string), let name = placeholder.capture { return [name] }
      return []
    case .array(let items): return items.reduce(into: []) { $0.formUnion(captures($1)) }
    case .object(let object): return object.values.reduce(into: []) { $0.formUnion(captures($1)) }
    default: return []
    }
  }

  /// `<kind>`, `<kind:name>` or `<~regex>`.
  struct Placeholder {
    var kind: String
    var capture: String?
    var pattern: String?

    static let kinds: Set<String> = [
      "any", "string", "number", "bool", "array", "object", "hex", "null",
    ]

    init?(_ string: String) {
      guard string.hasPrefix("<"), string.hasSuffix(">"), string.count > 2 else { return nil }
      let inner = String(string.dropFirst().dropLast())
      if inner.hasPrefix("~") {
        kind = "regex"
        pattern = String(inner.dropFirst())
        return
      }
      let parts = inner.split(separator: ":", maxSplits: 1).map(String.init)
      guard let first = parts.first, Self.kinds.contains(first) else { return nil }
      kind = first
      capture = parts.count == 2 ? parts[1] : nil
    }

    func matches(_ value: JSONValue) -> Bool {
      switch kind {
      case "any": return value != .null
      case "null": return value == .null
      case "string": return value.stringValue != nil
      case "number": return value.numberValue != nil
      case "bool": if case .bool = value { return true } else { return false }
      case "array": return value.arrayValue != nil
      case "object": return value.objectValue != nil
      case "hex":
        guard let string = value.stringValue, string.hasPrefix("0x") else { return false }
        return UInt64(string.dropFirst(2), radix: 16) != nil
      case "regex":
        guard let string = value.stringValue, let pattern else { return false }
        return string.range(of: pattern, options: .regularExpression) != nil
      default: return false
      }
    }
  }

  /// Nil when `actual` has the shape `expected` describes; else where and why not. Captures go
  /// into `vars`.
  static func mismatch(
    _ expected: JSONValue, _ actual: JSONValue, at path: String = "$",
    vars: inout [String: JSONValue]
  ) -> String? {
    switch expected {
    case .string(let string):
      if let placeholder = Placeholder(string) {
        guard placeholder.matches(actual) else {
          return "\(path): \(ToolRendering.json(actual)) is not \(string)"
        }
        if let name = placeholder.capture { vars[name] = actual }
        return nil
      }
      return actual == expected
        ? nil : "\(path): \(ToolRendering.json(actual)) is not \(ToolRendering.json(expected))"
    case .object(let object):
      guard let have = actual.objectValue else {
        return "\(path): \(ToolRendering.json(actual)) is not an object"
      }
      for key in object.keys.sorted() {
        guard let value = have[key] else {
          return "\(path).\(key): missing from \(ToolRendering.json(actual))"
        }
        if let why = mismatch(object[key]!, value, at: "\(path).\(key)", vars: &vars) {
          return why
        }
      }
      return nil
    case .array(let items):
      guard let have = actual.arrayValue else {
        return "\(path): \(ToolRendering.json(actual)) is not an array"
      }
      if items.isEmpty {
        return have.isEmpty ? nil : "\(path): \(ToolRendering.json(actual)) is not empty"
      }
      // Each listed element matches a distinct element of the answer, in any order.
      var unused = Array(have.indices)
      for (n, item) in items.enumerated() {
        var found: Int?
        for index in unused {
          var trial = vars
          if mismatch(item, have[index], at: "\(path)[\(n)]", vars: &trial) == nil {
            vars = trial
            found = index
            break
          }
        }
        guard let found else {
          return "\(path)[\(n)]: no element of \(ToolRendering.json(actual)) is like "
            + ToolRendering.json(item)
        }
        unused.removeAll { $0 == found }
      }
      return nil
    case .number(let number):
      return actual.numberValue == number
        ? nil : "\(path): \(ToolRendering.json(actual)) is not \(number)"
    default:
      return actual == expected
        ? nil : "\(path): \(ToolRendering.json(actual)) is not \(ToolRendering.json(expected))"
    }
  }

  // MARK: Running a session against vmlab serve

  /// A short throwaway `VMLAB_HOME` that sees the shared image cache and this host's slow probes.
  static func makeHome(_ tag: String) throws -> URL {
    _ = TestHomeSweep.done
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-\(tag)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let shared = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vmlab")
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"), withDestinationURL: shared.appending(path: "images"))
    let facts = shared.appending(path: SlowProbes.fileName)
    if FileManager.default.fileExists(atPath: facts.path) {
      try FileManager.default.copyItem(
        at: facts, to: home.appending(path: SlowProbes.fileName))
    }
    return home
  }

  /// Runs `session` call by call against a fresh server; records an issue at the first call
  /// whose answer has the wrong shape and stops there. Every VM, fleet and segment is removed
  /// afterwards, whatever happened.
  static func run(_ number: Int) async throws {
    let session = try #require(try load().first { $0.number == number }, "no session \(number)")
    VZRunnerIntegrationTests.signRunner()
    let home = try makeHome("g\(number)")
    let log = ProcessInfo.processInfo.environment["VMLAB_DEBUG_DIR"].map {
      URL(filePath: $0).appending(path: "agent-guide-\(number).log")
    }
    let client = try StdioMCPClient(
      binary: try TwoServersIntegrationTests.vmlabURL(), home: home, tag: "guide\(number)",
      stderr: log)
    do {
      try await client.initialize()
      var vars: [String: JSONValue] = [:]
      for step in session.steps {
        let arguments = substitute(step.arguments, vars)
        let started = ContinuousClock.now
        let result = try await client.call(step.tool, arguments.objectValue ?? [:])
        let took = ContinuousClock.now - started
        print(
          "[guide \(number)] AGENT.md:\(step.line) \(step.tool) (\(took)): \(result.text.prefix(600))"
        )
        if let log {
          let full = log.deletingLastPathComponent().appending(
            path: "agent-guide-\(number)-\(step.line).json")
          try? Data(result.text.utf8).write(to: full)
        }
        let place = "AGENT.md:\(step.line) \(step.tool)"
        guard result.isError == step.fails else {
          Issue.record(
            "\(place): \(step.fails ? "expected an error" : "failed"): \(result.text)")
          break
        }
        if step.tool == "vm_computer", !step.fails,
          !["cursor_position", "screen_info"].contains(arguments["action"]?.stringValue ?? "")
        {
          guard result.images == 1 else {
            Issue.record("\(place): \(result.images) images")
            break
          }
        }
        if let expected = step.expected {
          let expected = substitute(expected, vars)
          if let why = mismatch(expected, result.value, vars: &vars) {
            print("[guide \(number)] MISMATCH \(place): \(why.prefix(2000))")
            Issue.record("\(place): \(why)")
            break
          }
        }
      }
    } catch {
      Issue.record("session \(number): \(error)")
    }
    await cleanUp(client, home: home)
  }

  /// Destroys what a session left (fleets, VMs, segments) through the server, then kills any
  /// guest process it missed and removes the home.
  static func cleanUp(_ client: StdioMCPClient, home: URL) async {
    if let fleets = try? await client.call("fleet", ["action": "list"]).value["fleets"]?.arrayValue
    {
      for fleet in fleets {
        if let name = fleet["name"] {
          _ = try? await client.call("fleet", ["action": "destroy", "name": name])
        }
      }
    }
    if let vms = try? await client.call("vm_list", [:]).value["vms"]?.arrayValue {
      for vm in vms {
        if let id = vm["id"] {
          _ = try? await client.call(
            "vm_lifecycle", ["vm": id, "action": "destroy", "force": true])
        }
      }
    }
    if let segments = try? await client.call("net_segment", ["action": "list"]).value["segments"]?
      .arrayValue
    {
      for segment in segments {
        if let name = segment["name"] {
          _ = try? await client.call("net_segment", ["action": "destroy", "name": name])
        }
      }
    }
    client.terminate()
    let store = Store(home: home)
    for record in (try? store.list().records) ?? [] {
      if let pid = record.runtime?.pid, pid > 0 { Darwin.kill(pid, SIGKILL) }
      if let clone = record.tartClone {
        _ = try? await Tart.locate().delete(URL(filePath: clone).lastPathComponent)
      }
    }
    for pid in TwoServersIntegrationTests.qemuPIDs(in: home) { Darwin.kill(pid, SIGKILL) }
    try? FileManager.default.removeItem(at: home)
  }
}

@Suite(.serialized) struct AgentGuideTests {
  static let titles = [
    1: "fix a crashing window manager",
    2: "step a bootloader",
    3: "test a macOS setup script and diff",
    4: "three-node cluster",
    5: "bisect a kernel panic with checkpoints",
  ]

  /// The document parses into the five sessions, every call names a tool with arguments its
  /// schema accepts, has a result or error block, and refers only to values captured before it.
  @Test func guideSessionsAreWellFormed() throws {
    let sessions = try AgentGuide.load()
    #expect(sessions.map(\.number) == [1, 2, 3, 4, 5])
    for session in sessions {
      #expect(
        session.title.lowercased().contains(Self.titles[session.number]?.lowercased() ?? "?"),
        "session \(session.number): \(session.title)")
      #expect(session.steps.count >= 4, "session \(session.number) has too few calls")
      var known: Set<String> = []
      for step in session.steps {
        let place = "AGENT.md:\(step.line)"
        let handler = ToolHandlers.handler(named: step.tool)
        #expect(handler != nil, "\(place): no tool \(step.tool)")
        if let handler {
          #expect(throws: Never.self, "\(place)") {
            try ToolArguments(step.arguments, spec: handler.spec)
          }
        }
        #expect(step.expected != nil, "\(place): \(step.tool) has no result block")
        let missing = AgentGuide.references(step.arguments)
          .union(step.expected.map(AgentGuide.references) ?? []).subtracting(known)
        #expect(missing.isEmpty, "\(place): refers to \(missing) before capturing it")
        known.formUnion(step.expected.map(AgentGuide.captures) ?? [])
      }
    }
  }

  /// The matcher itself, on the cases the guide relies on.
  @Test func resultBlocksMatchAsDocumented() {
    var vars: [String: JSONValue] = [:]
    let actual: JSONValue = [
      "pc": "0x1000", "state": "running", "n": 3, "extra": true,
      "items": [["name": "a", "ip": "10.0.0.2"], ["name": "b", "ip": "10.0.0.3"]],
    ]
    #expect(
      AgentGuide.mismatch(
        [
          "pc": "<hex:pc>", "state": "running", "n": "<number>",
          "items": [["name": "b", "ip": "<~^10\\.0\\.0\\.>"]],
        ], actual, vars: &vars) == nil)
    #expect(vars["pc"] == "0x1000")
    #expect(AgentGuide.mismatch(["state": "stopped"], actual, vars: &vars) != nil)
    #expect(AgentGuide.mismatch(["missing": "<any>"], actual, vars: &vars) != nil)
    #expect(AgentGuide.mismatch(["items": []], actual, vars: &vars) != nil)
    #expect(
      AgentGuide.substitute(["address": "{{pc}}", "c": "x {{pc}}"], vars)
        == ["address": "0x1000", "c": "x 0x1000"])
  }

  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(30)))
  func session1CrashingWindowManager() async throws { try await AgentGuide.run(1) }

  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(6)))
  func session2StepABootloader() async throws { try await AgentGuide.run(2) }

  @Test(
    .enabled(if: VZMacGuestIntegrationTests.ready && VZMacGuestIntegrationTests.hostHasRoom()),
    .timeLimit(.minutes(15)))
  func session3MacOSSetupScriptAndDiff() async throws { try await AgentGuide.run(3) }

  @Test(.enabled(if: VZRunnerIntegrationTests.ready), .timeLimit(.minutes(10)))
  func session4ThreeNodeCluster() async throws { try await AgentGuide.run(4) }

  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func session5BisectAKernelPanic() async throws { try await AgentGuide.run(5) }
}
