import Darwin
import Dispatch

/// A byte stream to an RFB server.
public protocol RFBTransport: Sendable {
  /// Reads exactly `count` bytes, or throws `RFBError.connectionClosed`.
  func read(exactly count: Int) async throws -> [UInt8]
  func write(_ bytes: [UInt8]) async throws
  func close() async
}

/// Where an RFB server listens.
public enum RFBEndpoint: Sendable, Equatable {
  case unix(path: String)
  case tcp(host: String, port: UInt16)
}

/// A blocking POSIX socket driven from private dispatch queues, so a pending read never holds a
/// Swift concurrency thread. Reads and writes use separate queues and may overlap.
public final class SocketTransport: RFBTransport, @unchecked Sendable {
  private let fd: Int32
  private let readQueue = DispatchQueue(label: "vmlab.rfb.read")
  private let writeQueue = DispatchQueue(label: "vmlab.rfb.write")

  private init(fd: Int32) { self.fd = fd }

  deinit { Darwin.close(fd) }

  /// How long a TCP connect may take before it fails: an unreachable guest address would
  /// otherwise hold the caller for the kernel's own timeout (75 s and more).
  public static let defaultConnectTimeout = Duration.seconds(10)

  /// Opens a connection to `endpoint`, failing with `connectFailed` after `timeout`.
  public static func connect(
    _ endpoint: RFBEndpoint, timeout: Duration = defaultConnectTimeout
  ) async throws -> SocketTransport {
    try await withCheckedThrowingContinuation { cont in
      DispatchQueue.global().async {
        cont.resume(
          with: Result { try SocketTransport(fd: openSocket(endpoint, timeout: timeout)) })
      }
    }
  }

  private static func configure(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  }

  private static func openSocket(_ endpoint: RFBEndpoint, timeout: Duration) throws -> Int32 {
    switch endpoint {
    case .unix(let path):
      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let capacity = MemoryLayout.size(ofValue: addr.sun_path)
      guard path.utf8.count < capacity else {
        throw RFBError.connectFailed("socket path longer than \(capacity - 1) bytes: \(path)")
      }
      withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: path.utf8)
        buf[path.utf8.count] = 0
      }
      addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw RFBError.connectFailed(String(cString: strerror(errno))) }
      let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard rc == 0 else {
        let message = String(cString: strerror(errno))
        Darwin.close(fd)
        throw RFBError.connectFailed("\(path): \(message)")
      }
      configure(fd)
      return fd
    case .tcp(let host, let port):
      var hints = addrinfo()
      hints.ai_family = AF_UNSPEC
      hints.ai_socktype = SOCK_STREAM
      var list: UnsafeMutablePointer<addrinfo>?
      let gai = getaddrinfo(host, String(port), &hints, &list)
      guard gai == 0, let first = list else {
        throw RFBError.connectFailed("\(host): \(String(cString: gai_strerror(gai)))")
      }
      defer { freeaddrinfo(list) }
      var lastError = "no addresses"
      var cursor: UnsafeMutablePointer<addrinfo>? = first
      while let ai = cursor {
        cursor = ai.pointee.ai_next
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        if fd < 0 { continue }
        let failure = connect(fd, to: ai.pointee.ai_addr, length: ai.pointee.ai_addrlen, timeout)
        if failure == nil {
          configure(fd)
          return fd
        }
        lastError = failure ?? ""
        Darwin.close(fd)
      }
      throw RFBError.connectFailed("\(host):\(port): \(lastError)")
    }
  }

  /// Connects `fd` within `timeout`: non-blocking, waited for with `poll`, then blocking again.
  /// Nil on success, else why it failed.
  private static func connect(
    _ fd: Int32, to address: UnsafeMutablePointer<sockaddr>, length: socklen_t,
    _ timeout: Duration
  ) -> String? {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      return String(cString: strerror(errno))
    }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    if Darwin.connect(fd, address, length) == 0 { return nil }
    guard errno == EINPROGRESS else { return String(cString: strerror(errno)) }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      let left = ContinuousClock.now.duration(to: deadline)
      guard left > .zero else { return "no answer within \(timeout)" }
      let ms = Int32(
        clamping: left.components.seconds * 1000 + left.components.attoseconds
          / 1_000_000_000_000_000 + 1)
      var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      let ready = poll(&pfd, 1, ms)
      if ready < 0 && errno == EINTR { continue }
      if ready < 0 { return String(cString: strerror(errno)) }
      if ready == 0 { continue }
      var error: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
        return String(cString: strerror(errno))
      }
      return error == 0 ? nil : String(cString: strerror(error))
    }
  }

  public func read(exactly count: Int) async throws -> [UInt8] {
    if count == 0 { return [] }
    let fd = self.fd
    return try await withCheckedThrowingContinuation { cont in
      readQueue.async {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
          let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
          if n > 0 {
            got += n
          } else if n < 0 && errno == EINTR {
            continue
          } else {
            cont.resume(throwing: RFBError.connectionClosed)
            return
          }
        }
        cont.resume(returning: buf)
      }
    }
  }

  public func write(_ bytes: [UInt8]) async throws {
    let fd = self.fd
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      writeQueue.async {
        var sent = 0
        while sent < bytes.count {
          let n = bytes.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress! + sent, bytes.count - sent)
          }
          if n > 0 {
            sent += n
          } else if n < 0 && errno == EINTR {
            continue
          } else {
            cont.resume(throwing: RFBError.connectionClosed)
            return
          }
        }
        cont.resume()
      }
    }
  }

  /// Shuts the socket down, failing any pending read; the descriptor closes on deinit.
  public func close() async {
    shutdown(fd, SHUT_RDWR)
  }
}

/// Replays recorded server bytes and keeps what the client wrote. For tests and fixtures.
public actor ReplayTransport: RFBTransport {
  private let input: [UInt8]
  private var offset = 0
  public private(set) var written: [UInt8] = []

  public init(serverBytes: [UInt8]) { input = serverBytes }

  /// True when every recorded byte has been read.
  public var atEnd: Bool { offset == input.count }

  public func read(exactly count: Int) async throws -> [UInt8] {
    guard offset + count <= input.count else {
      offset = input.count
      throw RFBError.connectionClosed
    }
    defer { offset += count }
    return Array(input[offset..<(offset + count)])
  }

  public func write(_ bytes: [UInt8]) async throws { written += bytes }

  public func close() async {}
}
