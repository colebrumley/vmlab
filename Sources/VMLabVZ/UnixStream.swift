import Foundation
import VMLabCore

/// Blocking unix stream socket calls shared by the control client and the runner's server.
public enum UnixStream {
  /// Why a socket call failed, with `errno`.
  public struct Failure: Error, Sendable, CustomStringConvertible {
    public var call: String
    public var errno: Int32

    public var description: String { "\(call): \(String(cString: strerror(errno)))" }
  }

  /// The `sockaddr_un` for `path`; nil when the path does not fit `sun_path` (104 bytes on Darwin,
  /// terminator included).
  public static func address(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !bytes.isEmpty, bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    return address
  }

  /// The longest socket path `address(_:)` accepts.
  public static var maxPathBytes: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 }

  private static func socketFD() throws(Failure) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure(call: "socket", errno: errno) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    return fd
  }

  /// A connected socket to `path`.
  public static func connect(path: String) throws(Failure) -> Int32 {
    guard var address = address(path) else { throw Failure(call: "connect", errno: ENAMETOOLONG) }
    let fd = try socketFD()
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
    }
    guard result == 0 else {
      let code = errno
      close(fd)
      throw Failure(call: "connect", errno: code)
    }
    return fd
  }

  /// A listening socket bound at `path` (mode 0600). The path must not exist.
  public static func listen(path: String, backlog: Int32 = 16) throws(Failure) -> Int32 {
    guard var address = address(path) else { throw Failure(call: "bind", errno: ENAMETOOLONG) }
    let fd = try socketFD()
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let old = umask(0o077)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
    }
    umask(old)
    guard bound == 0, Darwin.listen(fd, backlog) == 0 else {
      let code = errno
      close(fd)
      throw Failure(call: "bind", errno: code)
    }
    return fd
  }

  /// Sets the send and receive timeouts; nil means block forever.
  public static func setTimeout(_ fd: Int32, _ timeout: Duration?) {
    var value = timeval()
    if let timeout {
      let (seconds, attoseconds) = timeout.components
      value.tv_sec = Int(max(seconds, 0))
      value.tv_usec = Int32(max(attoseconds, 0) / 1_000_000_000_000)
      if value.tv_sec == 0, value.tv_usec == 0 { value.tv_usec = 1 }
    }
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
  }

  /// Writes all of `data`.
  public static func writeAll(_ fd: Int32, _ data: Data) throws(Failure) {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { raw in
        Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw Failure(call: "write", errno: errno)
      }
      offset += written
    }
  }

  /// Reads up to `max` bytes; an empty result is end of stream.
  public static func read(_ fd: Int32, max: Int = 4096) throws(Failure) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: max)
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, max) }
      if count >= 0 { return Array(buffer.prefix(count)) }
      if errno == EINTR { continue }
      throw Failure(call: "read", errno: errno)
    }
  }
}
