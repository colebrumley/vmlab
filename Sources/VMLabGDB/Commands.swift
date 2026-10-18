import Foundation

/// The `Z`/`z` point types: breakpoints (0, 1) and watchpoints (2, 3, 4).
public enum BreakpointType: Int, Sendable, CaseIterable, Codable {
  case software = 0
  case hardware = 1
  case writeWatchpoint = 2
  case readWatchpoint = 3
  case accessWatchpoint = 4

  public var isWatchpoint: Bool { rawValue >= 2 }
}

/// One action of a `vCont` packet, optionally limited to a thread.
public struct VContAction: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case `continue` = "c"
    case step = "s"
  }

  public var kind: Kind
  public var thread: String?

  public init(_ kind: Kind, thread: String? = nil) {
    self.kind = kind
    self.thread = thread
  }

  public static let `continue` = VContAction(.continue)
  public static let step = VContAction(.step)
}

/// Payloads of the packets the client sends (without framing).
public enum GDBCommand {
  /// `qSupported` with the features this client understands.
  public static let qSupported = "qSupported:multiprocess+;swbreak+;hwbreak+;vContSupported+"
  public static let haltReason = "?"
  public static let vContQuery = "vCont?"
  public static let `continue` = "c"
  public static let step = "s"
  public static let readRegisters = "g"

  public static func writeRegisters(_ data: [UInt8]) -> String { "G" + Hex.encode(data) }

  public static func readRegister(_ number: Int) -> String { "p" + Hex.number(number) }

  public static func writeRegister(_ number: Int, value: [UInt8]) -> String {
    "P\(Hex.number(number))=\(Hex.encode(value))"
  }

  public static func readMemory(address: UInt64, length: Int) -> String {
    "m\(Hex.number(address)),\(Hex.number(length))"
  }

  public static func writeMemory(address: UInt64, bytes: [UInt8]) -> String {
    "M\(Hex.number(address)),\(Hex.number(bytes.count)):\(Hex.encode(bytes))"
  }

  /// `Z<type>,<addr>,<kind>`: `kind` is the breakpoint length (4 on arm64, 1 on x86) or, for a
  /// watchpoint, the number of bytes watched.
  public static func insertPoint(_ type: BreakpointType, address: UInt64, kind: Int) -> String {
    "Z\(type.rawValue),\(Hex.number(address)),\(Hex.number(kind))"
  }

  public static func removePoint(_ type: BreakpointType, address: UInt64, kind: Int) -> String {
    "z\(type.rawValue),\(Hex.number(address)),\(Hex.number(kind))"
  }

  public static func vCont(_ actions: [VContAction]) -> String {
    "vCont"
      + actions.map { action in
        ";" + action.kind.rawValue + (action.thread.map { ":" + $0 } ?? "")
      }.joined()
  }

  public static func readFeatures(annex: String, offset: Int, length: Int) -> String {
    "qXfer:features:read:\(annex):\(Hex.number(offset)),\(Hex.number(length))"
  }
}

/// What the stub said in reply to `qSupported`.
public struct StubFeatures: Sendable, Equatable {
  /// `name+` features.
  public var supported: Set<String>
  /// `name=value` features.
  public var values: [String: String]

  public init(supported: Set<String> = [], values: [String: String] = [:]) {
    self.supported = supported
    self.values = values
  }

  public static func parse(_ reply: String) -> StubFeatures {
    var features = StubFeatures()
    for item in reply.split(separator: ";") where !item.isEmpty {
      if let eq = item.firstIndex(of: "=") {
        features.values[String(item[..<eq])] = String(item[item.index(after: eq)...])
      } else if item.hasSuffix("+") {
        features.supported.insert(String(item.dropLast()))
      }
    }
    return features
  }

  /// `PacketSize`, the largest packet the stub accepts, if it said.
  public var packetSize: Int? { values["PacketSize"].flatMap { Int($0, radix: 16) } }

  public func supports(_ name: String) -> Bool { supported.contains(name) }
}

/// Parses a `vCont?` reply (`vCont;c;C;s;S`) into the action letters the stub supports.
public func parseVContActions(_ reply: String) -> Set<String>? {
  guard reply.hasPrefix("vCont") else { return nil }
  return Set(reply.split(separator: ";").dropFirst().map(String.init))
}
