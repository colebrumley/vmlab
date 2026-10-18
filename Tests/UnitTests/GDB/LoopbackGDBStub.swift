import Foundation
import VMLabGDB

/// A GDB stub on a loopback TCP port that serves exactly one client, like QEMU's: further
/// connections stay unanswered in the listen backlog (`.ignore`) or are accepted and closed at
/// once (`.hangUp`). Packets of the served client go to a `FakeGDBStub.Handler`.
final class LoopbackGDBStub: @unchecked Sendable {
  enum Others { case ignore, hangUp }

  let port: Int
  private let listener: Int32
  private let lock = NSLock()
  private var _received: [String] = []
  private var client: Int32 = -1

  var received: [String] { lock.withLock { _received } }

  init(others: Others = .ignore, handler: @escaping FakeGDBStub.Handler) throws {
    let server = socket(AF_INET, SOCK_STREAM, 0)
    listener = server
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, size) }
    }
    guard bound == 0, listen(server, 4) == 0 else { throw GDBError.connectionFailed("bind") }
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &size) }
    }
    port = Int(UInt16(bigEndian: address.sin_port))
    Thread { [self] in
      let fd = accept(server, nil, nil)
      guard fd >= 0 else { return }
      lock.withLock { client = fd }
      if others == .hangUp {
        Thread {
          while true {
            let other = accept(server, nil, nil)
            guard other >= 0 else { return }
            close(other)
          }
        }.start()
      }
      serve(fd, handler)
    }.start()
  }

  private func serve(_ fd: Int32, _ handler: FakeGDBStub.Handler) {
    var decoder = GDBPacketDecoder()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      guard count > 0 else { break }
      var out: [UInt8] = []
      var bytes = Array(buffer[0..<count])
      if let index = bytes.firstIndex(of: 0x03) {
        bytes.remove(at: index)
        lock.withLock { _received.append("^C") }
        for reply in handler("^C") { out += GDBPacket.frame(reply) }
      }
      for case .packet(let payload) in decoder.feed(bytes[...]) {
        let text = String(decoding: payload, as: UTF8.self)
        lock.withLock { _received.append(text) }
        out += GDBPacket.ack
        for reply in handler(text) { out += GDBPacket.frame(reply) }
      }
      if !out.isEmpty { _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
    }
    close(fd)
  }

  /// Closes the served client's connection from the stub's side.
  func hangUpClient() {
    lock.withLock {
      if client >= 0 { shutdown(client, SHUT_RDWR) }
    }
  }

  deinit {
    shutdown(listener, SHUT_RDWR)
    close(listener)
  }
}
