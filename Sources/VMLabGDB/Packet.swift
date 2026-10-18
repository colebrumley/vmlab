import Foundation

/// Framing of the GDB remote serial protocol: `$payload#cs`, acks, escapes and run-length encoding.
public enum GDBPacket {
  /// Bytes that must be escaped inside a packet (`}` followed by the byte XOR 0x20).
  static let escaped: Set<UInt8> = [0x23, 0x24, 0x7D, 0x2A]  // # $ } *

  /// The modulo-256 sum of `bytes`.
  public static func checksum<C: Collection<UInt8>>(_ bytes: C) -> UInt8 {
    bytes.reduce(0) { $0 &+ $1 }
  }

  /// Escapes `payload` for transmission.
  public static func escape(_ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(payload.count)
    for byte in payload {
      if escaped.contains(byte) {
        out.append(0x7D)
        out.append(byte ^ 0x20)
      } else {
        out.append(byte)
      }
    }
    return out
  }

  /// Reverses `escape`: used on binary replies such as `qXfer` data.
  public static func unescape(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(data.count)
    var iterator = data.makeIterator()
    while let byte = iterator.next() {
      if byte == 0x7D, let next = iterator.next() {
        out.append(next ^ 0x20)
      } else {
        out.append(byte)
      }
    }
    return out
  }

  /// Expands run-length encoding: `X*n` repeats `X` a further `n - 29` times.
  public static func expandRunLength(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(data.count)
    var index = 0
    while index < data.count {
      let byte = data[index]
      if byte == 0x2A, let last = out.last, index + 1 < data.count {
        let count = Int(data[index + 1]) - 29
        if count > 0 { out.append(contentsOf: repeatElement(last, count: count)) }
        index += 2
      } else {
        out.append(byte)
        index += 1
      }
    }
    return out
  }

  /// A complete frame for `payload`: `$`, the escaped payload, `#` and two hex checksum digits.
  public static func frame(_ payload: [UInt8]) -> [UInt8] {
    let body = escape(payload)
    return [0x24] + body + [0x23] + Array(Hex.byte(checksum(body)).utf8)
  }

  public static func frame(_ payload: String) -> [UInt8] { frame(Array(payload.utf8)) }

  /// The interrupt byte, sent outside any frame to stop a running target.
  public static let interrupt: [UInt8] = [0x03]
  public static let ack: [UInt8] = [0x2B]
  public static let nack: [UInt8] = [0x2D]
}

/// What the decoder recognised in the byte stream from the stub.
public enum GDBEvent: Sendable, Equatable {
  case ack
  case nack
  /// A packet with a valid checksum; the payload is run-length expanded but not unescaped.
  case packet([UInt8])
  /// A packet whose checksum did not match; the receiver answers `-`.
  case corrupt
}

/// Incremental decoder for bytes arriving from a stub. Feed chunks as they arrive.
public struct GDBPacketDecoder: Sendable {
  private enum State: Sendable {
    case idle
    case body(notification: Bool)
    case checksum(notification: Bool, first: UInt8?)
  }

  private var state = State.idle
  private var body: [UInt8] = []

  public init() {}

  public mutating func feed<C: Collection<UInt8>>(_ bytes: C) -> [GDBEvent] {
    var events: [GDBEvent] = []
    for byte in bytes {
      switch state {
      case .idle:
        switch byte {
        case 0x2B: events.append(.ack)
        case 0x2D: events.append(.nack)
        case 0x24, 0x25:  // $ or % (non-stop notification, discarded)
          body.removeAll(keepingCapacity: true)
          state = .body(notification: byte == 0x25)
        default: break  // line noise between packets
        }
      case .body(let notification):
        if byte == 0x23 {
          state = .checksum(notification: notification, first: nil)
        } else {
          body.append(byte)
        }
      case .checksum(let notification, nil):
        state = .checksum(notification: notification, first: byte)
      case .checksum(let notification, let first?):
        state = .idle
        if notification { continue }
        let text = String(decoding: [first, byte], as: UTF8.self)
        if let sum = UInt8(text, radix: 16), sum == GDBPacket.checksum(body) {
          events.append(.packet(GDBPacket.expandRunLength(body)))
        } else {
          events.append(.corrupt)
        }
      }
    }
    return events
  }
}

/// Hex helpers for the protocol's ASCII encodings.
public enum Hex {
  static let digits = Array("0123456789abcdef".utf8)

  public static func byte(_ value: UInt8) -> String {
    String(decoding: [digits[Int(value >> 4)], digits[Int(value & 0xF)]], as: UTF8.self)
  }

  public static func encode<C: Collection<UInt8>>(_ bytes: C) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for value in bytes {
      out.append(digits[Int(value >> 4)])
      out.append(digits[Int(value & 0xF)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Decodes pairs of hex digits; `nil` if the text is not hex or has odd length.
  public static func decode<S: StringProtocol>(_ text: S) -> [UInt8]? {
    let chars = Array(text.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    var index = 0
    while index < chars.count {
      guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
      out.append(high << 4 | low)
      index += 2
    }
    return out
  }

  static func nibble(_ char: UInt8) -> UInt8? {
    switch char {
    case 0x30...0x39: char - 0x30
    case 0x61...0x66: char - 0x61 + 10
    case 0x41...0x46: char - 0x41 + 10
    default: nil
    }
  }

  /// Hex of a number without leading zeros, as addresses and lengths are written in packets.
  public static func number<T: BinaryInteger>(_ value: T) -> String { String(value, radix: 16) }

  /// The little-endian value of up to eight bytes.
  public static func littleEndian(_ bytes: [UInt8]) -> UInt64? {
    guard bytes.count <= 8, !bytes.isEmpty else { return nil }
    return bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
  }
}
