import Foundation
import Synchronization
import VMLabCore

/// An image content block a tool result carries next to its JSON (screenshots, R-50x).
public struct ToolImage: Sendable, Hashable {
  public var data: Data
  public var mimeType: String

  public init(data: Data, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }
}

/// What a tool returns: the result object of Appendix C (always with `warnings`), plus any images.
/// The MCP server sends `value` as one text block of JSON; the CLI prints it with `--json`.
public struct ToolResult: Sendable, Hashable {
  public var value: JSONValue
  public var images: [ToolImage]

  /// `object` with `warnings` set (Appendix C: every result carries it).
  public init(_ object: [String: JSONValue], warnings: [String] = [], images: [ToolImage] = []) {
    var object = object
    object["warnings"] = .array(warnings.map { .string($0) })
    self.value = .object(object)
    self.images = images
  }

  /// `value` as compact JSON with sorted keys: the MCP `text` content.
  public var text: String { ToolRendering.json(value) }

  public var warnings: [String] {
    value["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }
}

/// Where a long call reports how far it has got. On the MCP server it sends
/// `notifications/progress` with the call's progress token; elsewhere, and when the client sent no
/// token, it does nothing. Long calls report through `during(_:every:_:)` (R-205), which sends a
/// step when the work starts and a heartbeat at least every `interval` until it ends.
public struct ToolProgress: Sendable {
  public typealias Send =
    @Sendable (_ progress: Double, _ total: Double?, _ message: String?) async
    -> Void

  private let send: Send?
  /// The last progress value sent, shared by every copy, so steps and heartbeats keep increasing.
  private let counter = Counter()

  public init(_ send: @escaping Send) { self.send = send }

  private init() { self.send = nil }

  /// Reports nothing.
  public static let none = ToolProgress()

  /// Whether anyone listens: false for `.none`.
  public var isReporting: Bool { send != nil }

  /// Reports `progress` (increasing on every call) out of `total` when known.
  public func report(_ progress: Double, total: Double? = nil, message: String? = nil) async {
    counter.value.withLock { $0 = max($0, progress) }
    await send?(progress, total, message)
  }

  /// Reports the next step: one more than the last progress value sent.
  public func step(_ message: String) async {
    guard let send else { return }
    let value = counter.value.withLock { value -> Double in
      value += 1
      return value
    }
    await send(value, nil, message)
  }

  /// Runs `body`, reporting `message` when it starts and `message (Ns)` every `interval` until it
  /// returns or throws, so a client sees progress on a call that takes longer than its timeout.
  /// Cancelling the calling task cancels `body` as usual; the heartbeat stops with it.
  public func during<T: Sendable>(
    _ message: String, every interval: Duration = .seconds(5),
    _ body: () async throws(VMLabError) -> T
  ) async throws(VMLabError) -> T {
    guard isReporting else { return try await body() }
    await step(message)
    let started = ContinuousClock.now
    let heartbeat = Task { [self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { return }
        let elapsed = (ContinuousClock.now - started).components.seconds
        await step("\(message) (\(elapsed) s)")
      }
    }
    defer { heartbeat.cancel() }
    return try await body()
  }

  private final class Counter: Sendable {
    let value = Mutex<Double>(0)
  }
}

/// What a handler may use: the VM store, the host probe and the limits, all under one
/// `VMLAB_HOME`, the backends with the `VMManager` that drives them, the image cache, the start
/// gate, plus where this call reports progress.
public struct ToolContext: Sendable {
  public var home: URL
  public var store: Store
  public var probe: HostProbe
  public var limits: ResourceLimits
  public var backends: BackendRegistry
  /// One per context, so actions on one VM are serialized across the calls that share it.
  public var manager: VMManager
  public var images: ImageStore
  /// Admission to guest starts (`vm_lifecycle start`, `vm_create` autostart).
  public var startGate: any StartGating
  /// This call's progress reporter; the MCP server sets it per `tools/call`.
  public var progress: ToolProgress = .none
  /// How often a long call reports while it waits (R-205: at least every 5 s).
  public var heartbeat: Duration = .seconds(5)

  /// A context on `home`; the default probe counts running guests from that store.
  public init(
    home: URL, probe: HostProbe? = nil, limits: ResourceLimits = .defaults,
    backends: BackendRegistry = Backends.shared, images: ImageStore? = nil,
    startGate: any StartGating = StartGate.shared
  ) {
    let store = Store(home: home)
    self.home = home
    self.store = store
    self.probe = probe ?? HostProbe(home: home, runningGuests: { store.runningGuests() })
    self.limits = limits
    self.backends = backends
    self.manager = VMManager(store: store, backends: backends)
    self.images = images ?? ImageStore(home: home)
    self.startGate = startGate
  }

  /// The context of this process: `VMLAB_HOME`, or `~/.vmlab`.
  public static func live() -> ToolContext { ToolContext(home: Store.defaultHome()) }

  /// The fast host facts gathered now, merged with the persisted slow probes.
  public func hostFacts() -> HostFacts { probe.gather() }
}

/// One tool's behaviour, shared by the MCP server (`tools/call`) and the CLI subcommand of the
/// same name. Arguments arrive checked against `spec`'s top-level properties.
public protocol ToolHandler: Sendable {
  var spec: ToolSpec { get }
  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
}

/// The handlers built so far, keyed by tool name. Items register theirs in `all` as they land.
public enum ToolHandlers {
  public static let all: [any ToolHandler] = [
    HostFactsHandler(), HostDoctorHandler(), VMPlanHandler(), VMCreateHandler(), VMListHandler(),
    VMInspectHandler(), VMLifecycleHandler(), VMExecHandler(), VMJobHandler(), VMLogsHandler(),
    ImagesHandler(), VMIntrospectHandler(), VMMemoryDumpHandler(),
  ]

  private static let byName: [String: any ToolHandler] = Dictionary(
    uniqueKeysWithValues: all.map { ($0.spec.name, $0) })

  /// The specs of the built tools, in Appendix C order: what `tools/list` returns.
  public static var specs: [ToolSpec] {
    ToolCatalog.all.filter { byName[$0.name] != nil }
  }

  /// The handler for `name`, or nil when the tool is unknown or not built yet.
  public static func handler(named name: String) -> (any ToolHandler)? { byName[name] }

  /// Checks `arguments` against the tool's schema and runs it. An unknown tool is
  /// `invalid_request` with field `name`.
  public static func call(_ name: String, arguments: JSONValue, context: ToolContext)
    async throws(VMLabError) -> ToolResult
  {
    guard let handler = byName[name] else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "no tool named \(name)",
        hint: "Call one of: \(specs.map(\.name).joined(separator: ", ")).")
    }
    let checked = try ToolArguments(arguments, spec: handler.spec)
    return try await handler.call(checked, context: context)
  }
}

/// A tool call's arguments, checked against the top level of the tool's input schema: an object,
/// no unknown fields, every required field present. Typed accessors raise `invalid_request`.
public struct ToolArguments: Sendable, Hashable {
  public let values: [String: JSONValue]

  public init(_ arguments: JSONValue, spec: ToolSpec) throws(VMLabError) {
    let values: [String: JSONValue]
    switch arguments {
    case .null: values = [:]
    case .object(let object): values = object
    default:
      throw VMLabError.invalidRequest(
        field: "arguments", reason: "arguments must be a JSON object",
        hint: "Send the arguments of \(spec.name) as an object.")
    }
    let properties = spec.inputSchema["properties"]?.objectValue ?? [:]
    for key in values.keys.sorted() where properties[key] == nil {
      let known = properties.keys.sorted().joined(separator: ", ")
      throw VMLabError.invalidRequest(
        field: key, reason: "\(spec.name) has no field \(key)",
        hint: known.isEmpty ? "\(spec.name) takes no arguments." : "Its fields are: \(known).")
    }
    let required = spec.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    for key in required where values[key] == nil || values[key] == .null {
      throw VMLabError.invalidRequest(
        field: key, reason: "\(key) is required", hint: "Add \(key) to the \(spec.name) call.")
    }
    self.values = values
  }

  public subscript(key: String) -> JSONValue? {
    values[key].flatMap { $0 == .null ? nil : $0 }
  }

  public func string(_ key: String) throws(VMLabError) -> String? {
    guard let value = self[key] else { return nil }
    guard let string = value.stringValue else { throw Self.mismatch(key, "a string") }
    return string
  }

  public func bool(_ key: String, default fallback: Bool = false) throws(VMLabError) -> Bool {
    guard let value = self[key] else { return fallback }
    guard case .bool(let bool) = value else { throw Self.mismatch(key, "true or false") }
    return bool
  }

  public func int(_ key: String) throws(VMLabError) -> Int? {
    guard let value = self[key] else { return nil }
    guard case .number(let number) = value, let int = Int(exactly: number) else {
      throw Self.mismatch(key, "an integer")
    }
    return int
  }

  static func mismatch(_ key: String, _ expected: String) -> VMLabError {
    .invalidRequest(field: key, reason: "\(key) must be \(expected)", hint: "Fix \(key) and retry.")
  }
}

/// JSON text for results and refusals. The MCP layer and the CLI print only through these.
public enum ToolRendering {
  /// `value` as JSON with sorted keys; `pretty` indents it for a terminal.
  public static func json(_ value: JSONValue, pretty: Bool = false) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting =
      pretty
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  /// The Appendix D object `{ code, message, hint, data }`: the text of an MCP `isError` result.
  public static func json(_ error: VMLabError, pretty: Bool = false) -> String {
    json((try? JSONValue(encoding: error)) ?? .string(error.message), pretty: pretty)
  }

  /// A refusal for a person at a terminal: code and message, then the hint.
  public static func text(_ error: VMLabError) -> String {
    var lines = ["error[\(error.code.rawValue)]: \(error.message)"]
    if !error.hint.isEmpty { lines.append("hint: \(error.hint)") }
    return lines.joined(separator: "\n")
  }

  /// An error that is not a `VMLabError`, as `internal` with an `id` (Appendix D).
  public static func internalError(_ error: any Error, doing what: String) -> VMLabError {
    VMLabError(
      code: .internal, message: "\(what) failed: \(error)",
      hint: "This is a bug in vmlab; the server log has the details.",
      data: ["id": .string(UUID().uuidString.lowercased())])
  }
}

extension JSONValue {
  /// `value` encoded as JSON (ISO 8601 dates) and read back as a `JSONValue`.
  public init(encoding value: some Encodable) throws(VMLabError) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do {
      self = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    } catch {
      throw ToolRendering.internalError(error, doing: "encoding a \(type(of: value))")
    }
  }

  /// The JSON text of this value, for decoding into a Core type.
  public var data: Data {
    (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
  }
}
