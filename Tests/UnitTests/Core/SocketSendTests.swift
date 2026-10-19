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

  static func isFree(_ lock: NSLock) -> Bool {
    let free = lock.try()
    if free { lock.unlock() }
    return free
  }

  /// `sendAll` waits in `poll`, so the tests run it off the cooperative pool.
  static func sendAllOffPool(
    _ bytes: [UInt8], lock: NSLock, stall: Duration,
    descriptor: @escaping @Sendable () -> Int32?
  ) async -> Result<Void, SocketSend.Failure> {
    await OffPool.run {
      Result { () throws(SocketSend.Failure) in
        try SocketSend.sendAll(bytes, lock: lock, stall: stall, descriptor: descriptor)
      }
    }
  }

  @Test func aPeerThatNeverReadsStallsAfterTheTimeout() async throws {
    let (fd, peer) = pair()
    defer {
      close(fd)
      close(peer)
    }
    let lock = NSLock()
    let result = await Self.sendAllOffPool(
      [UInt8](repeating: 1, count: 8 << 20), lock: lock, stall: .milliseconds(200),
      descriptor: { fd })
    #expect(throws: SocketSend.Failure.self) { try result.get() }
    // The lock is free once the call has returned, and was never held across a wait.
    #expect(Self.isFree(lock))
  }

  @Test func aShutdownDescriptorEndsTheWrite() async throws {
    let (fd, peer) = pair()
    defer {
      // `shut` is awaited before this runs: it uses `fd` until then, and closing first would
      // let it shut down a number another test has since been given.
      close(fd)
      close(peer)
    }
    let lock = NSLock()
    nonisolated(unsafe) var open = true
    async let shut: Void = OffPool.run {
      Thread.sleep(forTimeInterval: 0.2)
      lock.withLock {
        open = false
        _ = shutdown(fd, SHUT_RDWR)
      }
    }
    let started = ContinuousClock.now
    let result = await Self.sendAllOffPool(
      [UInt8](repeating: 1, count: 8 << 20), lock: lock, stall: .seconds(60),
      descriptor: { open ? fd : nil })
    await shut
    #expect(throws: SocketSend.Failure.self) { try result.get() }
    #expect(ContinuousClock.now - started < .seconds(30))
  }

  @Test func everyByteArrives() async throws {
    let (fd, peer) = pair()
    defer {
      // `received` is awaited on every path before this runs, so the reader is done with `peer`.
      close(fd)
      close(peer)
    }
    let payload = (0..<(1 << 20)).map { UInt8($0 & 0xFF) }
    async let received = OffPool.run { () -> [UInt8] in
      var got: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 65536)
      while got.count < payload.count {
        let n = buffer.withUnsafeMutableBytes { read(peer, $0.baseAddress, $0.count) }
        guard n > 0 else { break }
        got += buffer[0..<n]
      }
      return got
    }
    let sent = await Self.sendAllOffPool(
      payload, lock: NSLock(), stall: .seconds(10), descriptor: { fd })
    if case .failure = sent { shutdown(peer, SHUT_RDWR) }  // ends the reader
    #expect(throws: Never.self) { try sent.get() }
    #expect(await received == payload)
  }
}
