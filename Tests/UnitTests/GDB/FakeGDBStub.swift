import Foundation
import VMLabGDB

/// An in-memory GDB stub for tests: decodes the client's frames, acknowledges them and answers
/// through a handler or by replaying a recorded transcript.
final class FakeGDBStub: GDBTransport, @unchecked Sendable {
  /// Answers a client packet (or `"^C"` for the interrupt byte) with raw reply payloads, sent
  /// unescaped and framed with a correct checksum.
  typealias Handler = @Sendable (String) -> [String]

  let incoming: AsyncThrowingStream<[UInt8], any Error>
  private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
  private let lock = NSLock()
  private var buffer: [UInt8] = []
  private var handler: Handler
  private var _received: [String] = []
  private var _badFrames = 0
  private var _acksFromClient = 0
  private var _nacksFromClient = 0
  private var nacksToSend: Int
  private var _closed = false

  init(nackFirst: Int = 0, handler: @escaping Handler) {
    (incoming, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
    self.handler = handler
    self.nacksToSend = nackFirst
  }

  var received: [String] { lock.withLock { _received } }
  var badFrames: Int { lock.withLock { _badFrames } }
  var acksFromClient: Int { lock.withLock { _acksFromClient } }
  var nacksFromClient: Int { lock.withLock { _nacksFromClient } }
  var closed: Bool { lock.withLock { _closed } }

  static func frame(_ payload: String) -> [UInt8] {
    let body = Array(payload.utf8)
    return [UInt8(ascii: "$")] + body + [UInt8(ascii: "#")]
      + Array(Hex.byte(GDBPacket.checksum(body)).utf8)
  }

  /// Sends bytes to the client as they are.
  func inject(_ bytes: [UInt8]) { continuation.yield(bytes) }

  /// Sends a well-formed packet to the client.
  func push(_ payload: String) { continuation.yield(Self.frame(payload)) }

  /// Closes the connection from the stub's side.
  func hangUp() { continuation.finish() }

  func send(_ bytes: [UInt8]) async throws {
    var replies: [[UInt8]] = []
    lock.withLock {
      buffer.append(contentsOf: bytes)
      while let first = buffer.first {
        switch first {
        case UInt8(ascii: "+"):
          _acksFromClient += 1
          buffer.removeFirst()
        case UInt8(ascii: "-"):
          _nacksFromClient += 1
          buffer.removeFirst()
        case 0x03:
          buffer.removeFirst()
          _received.append("^C")
          replies += handler("^C").map(Self.frame)
        case UInt8(ascii: "$"):
          guard let hash = buffer.firstIndex(of: UInt8(ascii: "#")), hash + 2 < buffer.count
          else { return }
          let body = Array(buffer[1..<hash])
          let sum = String(decoding: buffer[hash + 1...hash + 2], as: UTF8.self)
          buffer.removeFirst(hash + 3)
          guard UInt8(sum, radix: 16) == GDBPacket.checksum(body) else {
            _badFrames += 1
            replies.append(GDBPacket.nack)
            continue
          }
          if nacksToSend > 0 {
            nacksToSend -= 1
            replies.append(GDBPacket.nack)
            continue
          }
          let payload = String(decoding: GDBPacket.unescape(body), as: UTF8.self)
          _received.append(payload)
          replies.append(GDBPacket.ack)
          replies += handler(payload).map(Self.frame)
        default:
          buffer.removeFirst()
        }
      }
    }
    for reply in replies { continuation.yield(reply) }
  }

  func close() async {
    lock.withLock { _closed = true }
    continuation.finish()
  }
}

/// Replays a transcript: each client packet must match the next `->` line; the `<-` lines after
/// it are the replies.
final class TranscriptReplay: @unchecked Sendable {
  enum Line: Equatable {
    case client(String)
    case stub(String)
  }

  let lines: [Line]
  private let lock = NSLock()
  private var index = 0
  private var _failures: [String] = []

  init(_ text: String) {
    lines = text.split(separator: "\n").compactMap { raw in
      let line = String(raw)
      if line.hasPrefix("-> ") { return .client(String(line.dropFirst(3))) }
      if line == "<-" { return .stub("") }
      if line.hasPrefix("<- ") { return .stub(String(line.dropFirst(3))) }
      return nil
    }
  }

  var failures: [String] { lock.withLock { _failures } }
  var finished: Bool { lock.withLock { index == lines.count } }

  func answer(_ packet: String) -> [String] {
    lock.withLock {
      guard index < lines.count, case .client(let expected) = lines[index] else {
        _failures.append("unexpected packet \(packet) at line \(index)")
        return []
      }
      guard expected == packet else {
        _failures.append("expected \(expected), got \(packet)")
        return []
      }
      index += 1
      var replies: [String] = []
      while index < lines.count, case .stub(let reply) = lines[index] {
        replies.append(reply)
        index += 1
      }
      return replies
    }
  }
}

enum GDBFixtures {
  static func text(_ name: String) throws -> String {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Fixtures/gdb/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
  }

  static func littleEndian(_ value: UInt64, bytes: Int = 8) -> String {
    Hex.encode((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
  }
}
