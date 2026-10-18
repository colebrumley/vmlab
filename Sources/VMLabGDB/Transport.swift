import Foundation
import VMLabCore

/// A byte pipe to a GDB stub. The client owns exactly one.
public protocol GDBTransport: Sendable {
  /// Sends bytes to the stub, in call order.
  func send(_ bytes: [UInt8]) async throws
  /// Chunks from the stub as they arrive; finishes when the stub closes the connection. Iterated
  /// once, by the client's reader.
  var incoming: AsyncThrowingStream<[UInt8], any Error> { get }
  /// Closes the connection; `incoming` then finishes.
  func close() async
}

/// A TCP connection to a stub such as QEMU's `-gdb tcp:127.0.0.1:<port>`, on a BSD socket with a
/// dedicated reader thread. The reader thread closes the descriptor when the stream ends, under
/// the same lock that guards writes, so a descriptor number is never reused under a writer.
public final class GDBTCPTransport: GDBTransport, Sendable {
  public let incoming: AsyncThrowingStream<[UInt8], any Error>
  private let socket: Socket
  /// A private serial queue: its own thread, unlike `DispatchQueue.global()`.
  private let writeQueue = DispatchQueue(label: "vmlab.gdb.writer")

  /// Connects to `host:port` (numeric or a name `getaddrinfo` resolves).
  public init(host: String, port: UInt16) throws {
    let fd = try Self.connect(host: host, port: port)
    let socket = Socket(fd: fd)
    self.socket = socket
    let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
    self.incoming = stream
    let thread = Thread {
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
          continuation.yield(Array(buffer[0..<count]))
        } else if count < 0 && errno == EINTR {
          continue
        } else {
          socket.finish()
          continuation.finish()
          return
        }
      }
    }
    thread.name = "vmlab.gdb.reader"
    thread.start()
  }

  /// `init` on a thread of its own: the `connect` (and a name lookup) block, and must not hold a
  /// thread of the cooperative pool while they do.
  public static func open(host: String, port: UInt16) async throws -> GDBTCPTransport {
    try await OffPool.run("vmlab.gdb.connect") { () throws(any Error) -> GDBTCPTransport in
      try GDBTCPTransport(host: host, port: port)
    }
  }

  deinit { socket.shutdown() }

  /// Writes on the transport's own serial queue, never on the cooperative pool (a stub that
  /// stops reading blocks the write). The queue keeps sends in call order: each is enqueued
  /// before the caller suspends.
  public func send(_ bytes: [UInt8]) async throws {
    let socket = self.socket
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
      writeQueue.async { done.resume(with: Result { try socket.write(bytes) }) }
    }
  }

  public func close() async { socket.shutdown() }

  private static func connect(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let first = result else {
      throw GDBError.connectionFailed("\(host):\(port): \(String(cString: gai_strerror(status)))")
    }
    defer { freeaddrinfo(result) }
    var lastError = ECONNREFUSED
    var candidate: UnsafeMutablePointer<addrinfo>? = first
    while let info = candidate {
      let fd = Darwin.socket(
        info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
      if fd >= 0 {
        if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
          var one: Int32 = 1
          let size = socklen_t(MemoryLayout<Int32>.size)
          setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, size)
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
          return fd
        }
        lastError = errno
        Darwin.close(fd)
      } else {
        lastError = errno
      }
      candidate = info.pointee.ai_next
    }
    throw GDBError.connectionFailed("\(host):\(port): \(String(cString: strerror(lastError)))")
  }

  /// The descriptor and its state, shared by writers and the reader thread.
  private final class Socket: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var finished = false

    init(fd: Int32) { self.fd = fd }

    func write(_ bytes: [UInt8]) throws {
      try lock.withLock {
        guard !finished else { throw GDBError.connectionClosed }
        var offset = 0
        while offset < bytes.count {
          let written = bytes[offset...].withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress, $0.count)
          }
          if written < 0 {
            if errno == EINTR { continue }
            throw GDBError.connectionClosed
          }
          offset += written
        }
      }
    }

    /// Ends both directions; the blocked reader sees end of file and calls `finish`.
    func shutdown() {
      lock.withLock {
        if !finished { _ = Darwin.shutdown(fd, SHUT_RDWR) }
      }
    }

    /// Called once by the reader thread when the stream ends.
    func finish() {
      lock.withLock {
        finished = true
        Darwin.close(fd)
      }
    }
  }
}
