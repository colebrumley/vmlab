import Foundation
import Testing
import VMLabSwitch

/// Three in-process ports on a running switch, the way QEMU's `-netdev dgram` attaches: each port
/// is a datagram socket bound to its own path and connected to `switch.sock`.
@Suite struct SwitchServerTests {
  final class Harness {
    let root: URL
    let paths: SegmentPaths
    let server: SwitchServer
    private var fds: [Int32] = []

    init() throws {
      // Short: sun_path holds 103 bytes.
      root = URL(filePath: NSTemporaryDirectory()).appending(
        path: "vsw-\(UInt32.random(in: 0...UInt32.max))")
      paths = SegmentPaths(directory: root.appending(path: "seg"))
      server = try SwitchServer(paths: paths)
      let server = self.server
      Thread { server.run() }.start()
    }

    /// A port bound to `ports/<name>.sock` and connected to the switch.
    func port(_ name: String) throws -> Int32 {
      let fd = try UnixSocket.make(SOCK_DGRAM)
      fds.append(fd)
      try UnixSocket.bind(fd, path: paths.portsDirectory.appending(path: "\(name).sock").path)
      try UnixSocket.connect(fd, path: paths.switchSocket.path)
      return fd
    }

    /// Closes a port early. Tests run in parallel in one process, so an fd closed twice can close
    /// another test's socket that reused the number; `stop()` must not close this one again.
    func close(_ fd: Int32) {
      fds.removeAll { $0 == fd }
      Darwin.close(fd)
    }

    func stop() {
      server.stop()
      let deadline = Date().addingTimeInterval(5)
      while FileManager.default.fileExists(atPath: paths.pidFile.path), Date() < deadline {
        usleep(10_000)
      }
      for fd in fds { Darwin.close(fd) }
      try? FileManager.default.removeItem(at: root)
    }

    func stats() throws -> SwitchStats {
      let fd = try UnixSocket.make(SOCK_STREAM)
      defer { close(fd) }
      try UnixSocket.connect(fd, path: paths.statsSocket.path)
      var data = Data()
      var buf = [UInt8](repeating: 0, count: 4096)
      while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(contentsOf: buf[..<n])
      }
      return try JSONDecoder().decode(SwitchStats.self, from: data)
    }

    /// Stats once the switch has received `count` frames (sends are asynchronous to it). The
    /// deadline is generous: the wait ends as soon as the count is reached, and a loaded host can
    /// leave the switch thread unscheduled for seconds.
    func stats(afterReceiving count: Int) throws -> SwitchStats {
      let deadline = Date().addingTimeInterval(30)
      var stats = try self.stats()
      while stats.received < count, Date() < deadline {
        usleep(5_000)
        stats = try self.stats()
      }
      return stats
    }
  }

  static func send(_ fd: Int32, _ frame: [UInt8]) {
    let sent = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    #expect(sent == frame.count)
  }

  /// The next frame on `fd`, or nil after `timeout` milliseconds. The default is for frames that
  /// must arrive, so it is generous; a frame that must not arrive passes a short timeout.
  static func receive(_ fd: Int32, timeout: Int32 = 20_000) -> [UInt8]? {
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&p, 1, timeout) == 1 else { return nil }
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = recv(fd, &buf, buf.count, 0)
    return n >= 0 ? Array(buf[..<n]) : nil
  }

  let a = SwitchCoreTests.mac(0xa)
  let b = SwitchCoreTests.mac(0xb)

  @Test func unicastReachesTheLearnedPortOnlyAndBroadcastReachesAllOthers() throws {
    let h = try Harness()
    defer { h.stop() }
    let (pa, pb, pc) = (try h.port("a"), try h.port("b"), try h.port("c"))
    // Register every port with the switch: a frame to nobody from each, before any learning test.
    for (fd, n) in [(pa, UInt8(0xa)), (pb, 0xb), (pc, 0xc)] {
      Self.send(
        fd, SwitchCoreTests.frame(to: SwitchCoreTests.mac(0xee), from: SwitchCoreTests.mac(n)))
    }
    _ = try h.stats(afterReceiving: 3)
    for fd in [pa, pb, pc] { while Self.receive(fd, timeout: 50) != nil {} }

    let hello = SwitchCoreTests.frame(to: SwitchCoreTests.broadcast, from: a)
    Self.send(pa, hello)
    #expect(Self.receive(pb) == hello)
    #expect(Self.receive(pc) == hello)
    #expect(Self.receive(pa, timeout: 100) == nil)

    let reply = SwitchCoreTests.frame(to: a, from: b, payload: 100)
    Self.send(pb, reply)
    #expect(Self.receive(pa) == reply)
    #expect(Self.receive(pc, timeout: 100) == nil)
    #expect(Self.receive(pb, timeout: 0) == nil)

    let stats = try h.stats(afterReceiving: 5)
    #expect(stats.ports == 3)
    #expect(stats.unicast == 1)
    #expect(stats.flooded == 4)
  }

  @Test func malformedAndOversizedFramesAreCountedAndDropped() throws {
    let h = try Harness()
    defer { h.stop() }
    let (pa, pb) = (try h.port("a"), try h.port("b"))
    Self.send(pb, SwitchCoreTests.frame(to: SwitchCoreTests.broadcast, from: b))
    Self.send(pa, [1, 2, 3])
    Self.send(pa, SwitchCoreTests.frame(to: SwitchCoreTests.broadcast, from: a, payload: 1700))
    let stats = try h.stats(afterReceiving: 3)
    #expect(stats.malformed == 1)
    #expect(stats.oversized == 1)
    #expect(Self.receive(pb, timeout: 100) == nil)
  }

  @Test func socketpairPortsJoinTheSegment() throws {
    let h = try Harness()
    defer { h.stop() }
    let pa = try h.port("a")
    // A port exists once the switch has seen a frame from it.
    Self.send(pa, SwitchCoreTests.frame(to: SwitchCoreTests.mac(0xee), from: a))
    _ = try h.stats(afterReceiving: 1)
    var pair: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0)
    defer { close(pair[1]) }
    h.server.attach(fd: pair[0])
    let fromPair = SwitchCoreTests.frame(to: SwitchCoreTests.broadcast, from: b)
    Self.send(pair[1], fromPair)
    #expect(Self.receive(pa) == fromPair)
    let toPair = SwitchCoreTests.frame(to: b, from: a)
    Self.send(pa, toPair)
    #expect(Self.receive(pair[1]) == toPair)
  }

  @Test func aDeadPortIsRemovedOnSend() throws {
    let h = try Harness()
    defer { h.stop() }
    let pa = try h.port("a")
    let pb = try h.port("b")
    Self.send(pa, SwitchCoreTests.frame(to: SwitchCoreTests.mac(0xee), from: a))
    _ = try h.stats(afterReceiving: 1)
    Self.send(pb, SwitchCoreTests.frame(to: SwitchCoreTests.broadcast, from: b))
    #expect(Self.receive(pa) != nil)
    h.close(pb)
    unlink(h.paths.portsDirectory.appending(path: "b.sock").path)
    Self.send(pa, SwitchCoreTests.frame(to: b, from: a))
    let deadline = Date().addingTimeInterval(30)
    var stats = try h.stats()
    while stats.ports != 1, Date() < deadline {
      usleep(5_000)
      stats = try h.stats()
    }
    #expect(stats.ports == 1)
    #expect(stats.macs == 1)
  }

  @Test func attachAndStopAfterTheSwitchHasStoppedTouchNoClosedFd() throws {
    let h = try Harness()
    h.stop()
    var pair: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0)
    defer { close(pair[1]) }
    // The switch owns pair[0] and, being stopped, closes it at once; neither call writes to the
    // wake pipe, whose number another test may already hold.
    h.server.attach(fd: pair[0])
    h.server.stop()
    let frame = SwitchCoreTests.frame(to: SwitchCoreTests.broadcast, from: a)
    let sent = frame.withUnsafeBytes { Darwin.send(pair[1], $0.baseAddress, $0.count, 0) }
    #expect(sent == -1)
  }

  @Test func aSecondSwitchOnALiveSegmentIsRefusedAndStopCleansUp() throws {
    let h = try Harness()
    #expect(throws: SwitchError.alreadyRunning(pid: getpid())) {
      try SwitchServer(paths: h.paths)
    }
    let paths = h.paths
    h.stop()
    #expect(!FileManager.default.fileExists(atPath: paths.switchSocket.path))
    #expect(!FileManager.default.fileExists(atPath: paths.pidFile.path))
  }
}
