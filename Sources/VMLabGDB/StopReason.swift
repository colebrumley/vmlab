import Foundation

/// A parsed stop reply (`S`, `T`, `W`, `X`), before the program counter is resolved.
public struct StopReply: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    /// The target stopped with a signal (`S`/`T`).
    case signal
    /// The process exited with this status (`W`).
    case exited(status: Int)
    /// The process was terminated by the signal (`X`).
    case terminated
  }

  public var kind: Kind
  public var signal: UInt8
  public var thread: String?
  /// Expedited registers, by register number, in target byte order.
  public var registers: [Int: [UInt8]]
  /// The other `key:value` pairs of a `T` reply (`watch`, `swbreak`, `core`, ...).
  public var info: [String: String]

  public init(
    kind: Kind, signal: UInt8, thread: String? = nil, registers: [Int: [UInt8]] = [:],
    info: [String: String] = [:]
  ) {
    self.kind = kind
    self.signal = signal
    self.thread = thread
    self.registers = registers
    self.info = info
  }

  /// Whether `payload` is a stop reply at all.
  public static func isStopReply(_ payload: String) -> Bool {
    guard let first = payload.first, "STWX".contains(first), payload.count >= 3 else {
      return false
    }
    return Hex.decode(payload.dropFirst().prefix(2)) != nil
  }

  public static func parse(_ payload: String) throws -> StopReply {
    guard isStopReply(payload), let code = Hex.decode(payload.dropFirst().prefix(2))?.first
    else {
      throw GDBError.malformedReply("not a stop reply: \(payload.prefix(64))")
    }
    let rest = payload.dropFirst(3)
    switch payload.first {
    case "S":
      return StopReply(kind: .signal, signal: code)
    case "W":
      return StopReply(kind: .exited(status: Int(code)), signal: 0)
    case "X":
      return StopReply(kind: .terminated, signal: code)
    default:
      var reply = StopReply(kind: .signal, signal: code)
      for pair in rest.split(separator: ";") where !pair.isEmpty {
        let parts = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]) : ""
        if key == "thread" {
          reply.thread = value
        } else if let number = Int(key, radix: 16), let bytes = Hex.decode(value) {
          reply.registers[number] = bytes
        } else {
          reply.info[key] = value
        }
      }
      return reply
    }
  }
}

/// Why the target stopped, with the program counter resolved through the register map.
public struct StopReason: Sendable, Equatable {
  /// A watchpoint that triggered: what kind and the data address.
  public struct WatchpointHit: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
      case write = "watch"
      case read = "rwatch"
      case access = "awatch"
    }

    public var kind: Kind
    public var address: UInt64

    public init(kind: Kind, address: UInt64) {
      self.kind = kind
      self.address = address
    }
  }

  public var kind: StopReply.Kind
  public var signal: UInt8
  public var thread: String?
  public var pc: UInt64?
  public var watchpoint: WatchpointHit?
  /// Set when the stub reported a software (`swbreak`) or hardware (`hwbreak`) breakpoint.
  public var breakpoint: BreakpointType?

  public init(
    kind: StopReply.Kind, signal: UInt8, thread: String? = nil, pc: UInt64? = nil,
    watchpoint: WatchpointHit? = nil, breakpoint: BreakpointType? = nil
  ) {
    self.kind = kind
    self.signal = signal
    self.thread = thread
    self.pc = pc
    self.watchpoint = watchpoint
    self.breakpoint = breakpoint
  }

  /// Builds a reason from a reply; `pcRegister` is the pc's register number, if known.
  public init(reply: StopReply, pcRegister: Int?) {
    self.init(kind: reply.kind, signal: reply.signal, thread: reply.thread)
    if let number = pcRegister, let bytes = reply.registers[number] {
      pc = Hex.littleEndian(bytes)
    }
    for kind in [WatchpointHit.Kind.write, .read, .access] {
      if let text = reply.info[kind.rawValue], let address = UInt64(text, radix: 16) {
        watchpoint = WatchpointHit(kind: kind, address: address)
      }
    }
    if reply.info["swbreak"] != nil { breakpoint = .software }
    if reply.info["hwbreak"] != nil { breakpoint = .hardware }
  }
}
