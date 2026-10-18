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

extension UnixSocket {
  /// `CMSG_SPACE(sizeof(int))` and `CMSG_LEN(sizeof(int))` on Darwin: a 12-byte `cmsghdr`
  /// (4-byte aligned) followed by the descriptor.
  static let controlHeader = MemoryLayout<cmsghdr>.size
  static let controlLength = controlHeader + MemoryLayout<Int32>.size

  /// Sends `descriptor` over the connected unix stream `socket` with one byte of data
  /// (`SCM_RIGHTS`). The caller still owns its copy.
  public static func sendDescriptor(_ descriptor: Int32, over socket: Int32) throws {
    var byte: UInt8 = 0x2A
    var control = [UInt8](repeating: 0, count: controlLength)
    control.withUnsafeMutableBytes { raw in
      let header = raw.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
      header.pointee.cmsg_len = socklen_t(controlLength)
      header.pointee.cmsg_level = SOL_SOCKET
      header.pointee.cmsg_type = SCM_RIGHTS
      raw.storeBytes(of: descriptor, toByteOffset: controlHeader, as: Int32.self)
    }
    let sent = withUnsafeMutablePointer(to: &byte) { bytePointer in
      control.withUnsafeMutableBytes { raw in
        var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
          var message = msghdr(
            msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
            msg_control: raw.baseAddress, msg_controllen: socklen_t(controlLength), msg_flags: 0)
          return sendmsg(socket, &message, 0)
        }
      }
    }
    guard sent == 1 else { throw SwitchError.system(call: "sendmsg", errno: errno) }
  }

  /// Receives one descriptor sent by `sendDescriptor`; nil when the peer sent none.
  public static func receiveDescriptor(from socket: Int32) throws -> Int32? {
    var byte: UInt8 = 0
    var control = [UInt8](repeating: 0, count: controlLength + 16)
    let (received, length) = withUnsafeMutablePointer(to: &byte) { bytePointer in
      control.withUnsafeMutableBytes { raw in
        var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
          var message = msghdr(
            msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
            msg_control: raw.baseAddress, msg_controllen: socklen_t(raw.count), msg_flags: 0)
          let count = recvmsg(socket, &message, 0)
          return (count, Int(message.msg_controllen))
        }
      }
    }
    guard received >= 0 else { throw SwitchError.system(call: "recvmsg", errno: errno) }
    guard length >= controlLength else { return nil }
    return control.withUnsafeBytes { raw in
      let header = raw.load(as: cmsghdr.self)
      guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return nil }
      return raw.load(fromByteOffset: controlHeader, as: Int32.self)
    }
  }
}
