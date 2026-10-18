import Foundation
import VMLabCore

/// What a client asks a `vmlab-vz` runner over `<vm>/control.sock`. One JSON object per line.
public enum ControlCommand: String, Codable, CaseIterable, Sendable {
  /// The guest's state; changes nothing.
  case status
  case pause, resume
  /// Asks the guest to shut down (`requestStop`, the ACPI power button); returns at once.
  case stop
  /// Stops the guest at once, like pulling the power cord.
  case kill
  /// Writes the paused guest's machine state to `path`.
  case save
  /// Restores a stopped guest from `path`; the guest is then paused.
  case restore
  /// Stops the guest if it runs and ends the runner process.
  case exit

  /// Whether the command needs a `path`.
  public var takesPath: Bool { self == .save || self == .restore }
}

/// The runner's view of its guest: `VZVirtualMachine.State`, named.
public enum RunnerState: String, Codable, CaseIterable, Sendable {
  case stopped, starting, running, pausing, paused, resuming, stopping, saving, restoring, error

  /// The `VMState` a server records for a guest whose runner reports this state; nil for the
  /// transitional states, which are not settled yet.
  public var vmState: VMState? {
    switch self {
    case .running: .running
    case .paused: .paused
    case .stopped: .stopped
    case .error: .broken
    case .starting, .pausing, .resuming, .stopping, .saving, .restoring: nil
    }
  }
}

/// One request line: `{"command":"save","path":"/abs/state.vzsave"}`.
public struct ControlRequest: Codable, Sendable, Hashable {
  public var command: ControlCommand
  public var path: String?

  public init(_ command: ControlCommand, path: String? = nil) {
    self.command = command
    self.path = path
  }
}

/// One response line: `{"ok":true,"state":"paused","pid":123}`, or `ok: false` with an Appendix D
/// `error`.
public struct ControlResponse: Codable, Sendable, Hashable {
  public var ok: Bool
  public var state: RunnerState?
  public var pid: Int32?
  public var error: VMLabError?

  public init(ok: Bool, state: RunnerState? = nil, pid: Int32? = nil, error: VMLabError? = nil) {
    self.ok = ok
    self.state = state
    self.pid = pid
    self.error = error
  }

  public static func success(_ state: RunnerState, pid: Int32? = nil) -> ControlResponse {
    ControlResponse(ok: true, state: state, pid: pid)
  }

  public static func failure(_ error: VMLabError, state: RunnerState? = nil) -> ControlResponse {
    ControlResponse(ok: false, state: state, error: error)
  }
}

/// The newline-delimited JSON codec both ends of the control socket use.
public enum ControlCodec {
  /// The longest line either end accepts, newline excluded.
  public static let maxLineBytes = 64 * 1024

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// `value` as one JSON line ending in `\n`. JSONEncoder never emits a raw newline.
  public static func line(_ value: some Encodable) throws(VMLabError) -> Data {
    do {
      var data = try encoder.encode(value)
      data.append(UInt8(ascii: "\n"))
      return data
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot encode a control message: \(error)",
        hint: "This is a vmlab bug; report it.")
    }
  }

  /// Decodes and validates a request line (trailing `\n` or `\r\n` allowed). A malformed line, an
  /// unknown command, or a `path` that is missing, relative or given to a command that takes none
  /// is `invalid_request`.
  public static func decodeRequest(_ line: Data) throws(VMLabError) -> ControlRequest {
    let request: ControlRequest
    do {
      request = try JSONDecoder().decode(ControlRequest.self, from: trimmed(line))
    } catch {
      throw VMLabError.invalidRequest(
        field: "command", reason: "not a control request: \(describe(error))",
        hint:
          "Send one JSON object per line with \"command\" one of "
          + ControlCommand.allCases.map(\.rawValue).joined(separator: ", ") + ".")
    }
    if request.command.takesPath {
      guard let path = request.path, path.hasPrefix("/") else {
        throw VMLabError.invalidRequest(
          field: "path", reason: "\(request.command.rawValue) needs an absolute path",
          hint: "Pass \"path\" as an absolute file path.")
      }
    } else if request.path != nil {
      throw VMLabError.invalidRequest(
        field: "path", reason: "\(request.command.rawValue) takes no path",
        hint: "Only save and restore take \"path\".")
    }
    return request
  }

  /// Decodes a response line. Anything else is `engine_error`: the runner spoke nonsense.
  public static func decodeResponse(_ line: Data) throws(VMLabError) -> ControlResponse {
    do {
      return try JSONDecoder().decode(ControlResponse.self, from: trimmed(line))
    } catch {
      throw VMLabError(
        code: .engineError, message: "The VZ runner sent an unreadable reply: \(describe(error))",
        hint: "Check <vm>/vz.log; the runner may be from another vmlab build.",
        data: ["reply": .string(String(decoding: line.prefix(200), as: UTF8.self))])
    }
  }

  private static func trimmed(_ line: Data) -> Data {
    var data = line
    while let last = data.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
      data.removeLast()
    }
    return data
  }

  private static func describe(_ error: any Error) -> String {
    switch error {
    case DecodingError.dataCorrupted(let context): context.debugDescription
    case DecodingError.keyNotFound(let key, _): "missing \"\(key.stringValue)\""
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
      "bad \"\(context.codingPath.map(\.stringValue).joined(separator: "."))\""
    default: "\(error)"
    }
  }
}

/// Splits a byte stream into lines. A line longer than `ControlCodec.maxLineBytes` is an error.
public struct LineBuffer: Sendable {
  private var pending = Data()

  public init() {}

  /// Appends `bytes` and returns every line they completed, without the `\n`.
  public mutating func feed(_ bytes: some Sequence<UInt8>) throws(VMLabError) -> [Data] {
    pending.append(contentsOf: bytes)
    var lines: [Data] = []
    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
      let line = Data(pending[pending.startIndex..<newline])
      pending = Data(pending[pending.index(after: newline)...])
      // A line that arrived whole in one chunk is held to the limit too.
      guard line.count <= ControlCodec.maxLineBytes else { throw overlong() }
      lines.append(line)
    }
    guard pending.count <= ControlCodec.maxLineBytes else { throw overlong() }
    return lines
  }

  private mutating func overlong() -> VMLabError {
    pending = Data()
    return VMLabError.invalidRequest(
      field: "line", reason: "a control line exceeds \(ControlCodec.maxLineBytes) bytes",
      hint: "Send one short JSON object per line.")
  }
}
