import Darwin
import Foundation
import Testing
import VMLabCore

@Suite struct SocketSendTests {
  func pair() -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    var on: Int32 = 1
    setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    SocketSend.setNonBlocking(fds[0])
    return (fds[0], fds[1])
  }

  @Test func aPeerThatNeverReadsStallsAfterTheTimeout() throws {
    let (fd, peer) = pair()
    defer {
      close(fd)
      close(peer)
    }
    let lock = NSLock()
    #expect(throws: SocketSend.Failure.self) {
      try SocketSend.sendAll(
        [UInt8](repeating: 1, count: 8 << 20), lock: lock, stall: .milliseconds(200),
        descriptor: { fd })
    }
    // The lock is free once the call has returned, and was never held across a wait.
    #expect(lock.try())
    lock.unlock()
  }

  @Test func aShutdownDescriptorEndsTheWrite() throws {
    let (fd, peer) = pair()
    defer {
      close(fd)
      close(peer)
    }
    let lock = NSLock()
    nonisolated(unsafe) var open = true
    let shut = Thread {
      Thread.sleep(forTimeInterval: 0.2)
      lock.withLock {
        open = false
        _ = shutdown(fd, SHUT_RDWR)
      }
    }
    shut.start()
    let started = ContinuousClock.now
    #expect(throws: SocketSend.Failure.self) {
      try SocketSend.sendAll(
        [UInt8](repeating: 1, count: 8 << 20), lock: lock, stall: .seconds(60),
        descriptor: { open ? fd : nil })
    }
    #expect(ContinuousClock.now - started < .seconds(30))
  }

  @Test func everyByteArrives() throws {
    let (fd, peer) = pair()
    defer {
      close(fd)
      close(peer)
    }
    let payload = (0..<(1 << 20)).map { UInt8($0 & 0xFF) }
    let done = DispatchSemaphore(value: 0)
    let reader = Thread {
      var got: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 65536)
      while got.count < payload.count {
        let n = buffer.withUnsafeMutableBytes { read(peer, $0.baseAddress, $0.count) }
        guard n > 0 else { break }
        got += buffer[0..<n]
      }
      #expect(got == payload)
      done.signal()
    }
    reader.start()
    try SocketSend.sendAll(payload, lock: NSLock(), stall: .seconds(10), descriptor: { fd })
    #expect(done.wait(timeout: .now() + 30) == .success)
  }
}
