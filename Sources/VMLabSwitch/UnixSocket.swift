import Foundation

/// Thin wrappers over the BSD socket calls the switch needs, for `AF_UNIX` only.
public enum UnixSocket {
  /// A `sockaddr_un` for `path`, or `pathTooLong` when it does not fit in `sun_path`.
  public static func address(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      throw SwitchError.pathTooLong(path)
    }
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: bytes)
      buf[bytes.count] = 0
    }
    return addr
  }

  /// The path in a `sockaddr_un` filled in by `recvfrom`; empty for an unbound sender.
  public static func path(of addr: sockaddr_un, length: socklen_t) -> String {
    let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 2
    let available = max(0, min(Int(length) - offset, MemoryLayout.size(ofValue: addr.sun_path)))
    return withUnsafeBytes(of: addr.sun_path) { buf in
      let bytes = buf.prefix(available)
      let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
      return String(decoding: bytes[..<end], as: UTF8.self)
    }
  }

  public static func make(_ type: Int32) throws -> Int32 {
    let fd = socket(AF_UNIX, type, 0)
    guard fd >= 0 else { throw SwitchError.system(call: "socket", errno: errno) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
  }

  public static func bind(_ fd: Int32, path: String) throws {
    var addr = try address(path)
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0 else { throw SwitchError.system(call: "bind \(path)", errno: errno) }
  }

  public static func connect(_ fd: Int32, path: String) throws {
    var addr = try address(path)
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0 else { throw SwitchError.system(call: "connect \(path)", errno: errno) }
  }

  public static func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
  }

  /// Raises a buffer size; macOS defaults unix datagram receive buffers to a few kilobytes.
  public static func setBuffer(_ fd: Int32, option: Int32, bytes: Int32) {
    var value = bytes
    setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size))
  }
}
