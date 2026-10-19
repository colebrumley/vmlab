import Darwin
import Foundation
import Testing
import VMLabSwitch

@Suite struct UnixSocketTests {
  /// Sends `descriptors` in one `SCM_RIGHTS` message.
  func send(_ descriptors: [Int32], over socket: Int32) {
    let header = MemoryLayout<cmsghdr>.size
    let length = header + descriptors.count * MemoryLayout<Int32>.size
    var control = [UInt8](repeating: 0, count: length)
    control.withUnsafeMutableBytes { raw in
      var cmsg = cmsghdr()
      cmsg.cmsg_len = socklen_t(length)
      cmsg.cmsg_level = SOL_SOCKET
      cmsg.cmsg_type = SCM_RIGHTS
      raw.storeBytes(of: cmsg, as: cmsghdr.self)
      for (i, fd) in descriptors.enumerated() {
        raw.storeBytes(of: fd, toByteOffset: header + i * 4, as: Int32.self)
      }
    }
    var byte: UInt8 = 0
    let sent = withUnsafeMutablePointer(to: &byte) { bytePointer in
      control.withUnsafeMutableBytes { raw in
        var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
          var message = msghdr(
            msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
            msg_control: raw.baseAddress, msg_controllen: socklen_t(length), msg_flags: 0)
          return sendmsg(socket, &message, 0)
        }
      }
    }
    #expect(sent == 1)
  }

  /// P3: descriptors past the first in one message are closed, not leaked. Three copies of a
  /// pipe's write end are sent; once the first and the local copies are closed, the read end
  /// sees end of file only if the receiver closed the other two.
  @Test func extraDescriptorsAreClosed() async throws {
    var pair: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      close(pair[0])
      close(pair[1])
    }
    var pipeEnds: [Int32] = [-1, -1]
    #expect(pipe(&pipeEnds) == 0)
    defer { close(pipeEnds[0]) }
    let copies = [pipeEnds[1], dup(pipeEnds[1]), dup(pipeEnds[1])]
    send(copies, over: pair[0])
    for fd in copies { close(fd) }
    let received = try #require(try UnixSocket.receiveDescriptor(from: pair[1]))
    close(received)
    // Not at once: a child another test is spawning holds a copy for a few ms (`SpawnWindow`).
    #expect(
      await SpawnWindow.reachesEndOfFile(pipeEnds[0]),
      "a received copy of the write end is still open")
  }
}
