import Foundation

/// One segment's switch: frames arrive on `switch.sock`, each sender becomes a port with its own
/// connected datagram socket, and `SwitchCore` decides where each frame goes. Single-threaded:
/// `run()` owns every socket; `stop()` and `attach(fd:)` are safe from any thread.
public final class SwitchServer: @unchecked Sendable {
  public typealias PortID = SwitchCore.PortID

  /// Frames handled per readable socket before the loop looks at the others.
  static let batch = 256
  static let socketBuffer: Int32 = 4 << 20

  public let paths: SegmentPaths
  private let dataFD: Int32
  private let statsFD: Int32
  private let wakeRead: Int32
  private let wakeWrite: Int32

  // Owned by the thread in `run()`.
  private var core: SwitchCore
  private struct Port {
    let fd: Int32
    let peer: String?
  }
  private var ports: [PortID: Port] = [:]
  private var portsByPeer: [String: PortID] = [:]
  private var nextPort: PortID = 1
  private var buffer = [UInt8](repeating: 0, count: 65536)

  private let lock = NSLock()
  private var stopping = false
  private var pending: [Int32] = []
  private var closed = false

  /// Creates the segment directory, binds `switch.sock` and `stats.sock`, and writes `switch.pid`.
  /// Stale sockets from a switch that died are replaced; a live one is `alreadyRunning`.
  public init(paths: SegmentPaths, agingSeconds: Double = 300) throws {
    self.paths = paths
    core = SwitchCore(agingSeconds: agingSeconds)
    let fm = FileManager.default
    _ = try UnixSocket.address(paths.switchSocket.path)
    _ = try UnixSocket.address(paths.statsSocket.path)
    try fm.createDirectory(at: paths.portsDirectory, withIntermediateDirectories: true)
    if let text = try? String(contentsOf: paths.pidFile, encoding: .utf8),
      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
      kill(pid, 0) == 0 || errno == EPERM
    {
      throw SwitchError.alreadyRunning(pid: pid)
    }
    unlink(paths.switchSocket.path)
    unlink(paths.statsSocket.path)

    var fds: [Int32] = []
    do {
      let data = try UnixSocket.make(SOCK_DGRAM)
      fds.append(data)
      UnixSocket.setBuffer(data, option: SO_RCVBUF, bytes: Self.socketBuffer)
      try UnixSocket.bind(data, path: paths.switchSocket.path)
      UnixSocket.setNonBlocking(data)

      let stats = try UnixSocket.make(SOCK_STREAM)
      fds.append(stats)
      try UnixSocket.bind(stats, path: paths.statsSocket.path)
      guard listen(stats, 16) == 0 else { throw SwitchError.system(call: "listen", errno: errno) }
      UnixSocket.setNonBlocking(stats)

      var pipeFDs: [Int32] = [0, 0]
      guard pipe(&pipeFDs) == 0 else { throw SwitchError.system(call: "pipe", errno: errno) }
      fds += pipeFDs
      UnixSocket.setNonBlocking(pipeFDs[0])
      UnixSocket.setNonBlocking(pipeFDs[1])

      try "\(getpid())\n".write(to: paths.pidFile, atomically: true, encoding: .utf8)
      (dataFD, statsFD, wakeRead, wakeWrite) = (data, stats, pipeFDs[0], pipeFDs[1])
    } catch {
      for fd in fds { close(fd) }
      unlink(paths.switchSocket.path)
      unlink(paths.statsSocket.path)
      throw error
    }
  }

  deinit { cleanup() }

  /// Makes `run()` return; it then closes every socket and removes the sockets and pid file.
  public func stop() {
    lock.withLock { stopping = true }
    wake()
  }

  /// Adds a port on an already connected datagram socket (one end of a `socketpair`); the switch
  /// owns `fd` from now on.
  public func attach(fd: Int32) {
    lock.withLock { pending.append(fd) }
    wake()
  }

  /// Switches frames until `stop()`.
  public func run() {
    while true {
      let (stop, attached) = lock.withLock {
        defer { pending = [] }
        return (stopping, pending)
      }
      if stop {
        for fd in attached { close(fd) }
        break
      }
      for fd in attached {
        UnixSocket.setNonBlocking(fd)
        UnixSocket.setBuffer(fd, option: SO_RCVBUF, bytes: Self.socketBuffer)
        addPort(Port(fd: fd, peer: nil))
      }

      let readable = ports.filter { $0.value.peer == nil }.map { ($0.key, $0.value.fd) }
      var fds = [wakeRead, dataFD, statsFD].map {
        pollfd(fd: $0, events: Int16(POLLIN), revents: 0)
      }
      fds += readable.map { pollfd(fd: $0.1, events: Int16(POLLIN), revents: 0) }
      guard poll(&fds, nfds_t(fds.count), -1) >= 0 else {
        if errno == EINTR { continue }
        break
      }
      if fds[0].revents != 0 {
        var byte: UInt8 = 0
        while read(wakeRead, &byte, 1) > 0 {}
      }
      if fds[1].revents & Int16(POLLIN) != 0 { receiveOnSwitchSocket() }
      if fds[2].revents & Int16(POLLIN) != 0 { serveStats() }
      for (index, (port, fd)) in readable.enumerated() {
        // A delivery earlier in this pass may have removed the port and closed its fd, and another
        // thread may since have been given that number: never touch an fd the port no longer owns.
        guard ports[port]?.fd == fd else { continue }
        let events = fds[3 + index].revents
        if events & Int16(POLLIN) != 0 {
          receive(on: fd, port: port)
        } else if events & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
          removePort(port)
        }
      }
    }
    cleanup()
  }

  private func wake() {
    var byte: UInt8 = 1
    _ = write(wakeWrite, &byte, 1)
  }

  private func receiveOnSwitchSocket() {
    for _ in 0..<Self.batch {
      var addr = sockaddr_un()
      var length = socklen_t(MemoryLayout<sockaddr_un>.size)
      let count = buffer.withUnsafeMutableBytes { buf in
        withUnsafeMutablePointer(to: &addr) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(dataFD, buf.baseAddress, buf.count, 0, $0, &length)
          }
        }
      }
      guard count >= 0 else { return }
      let peer = UnixSocket.path(of: addr, length: length)
      guard let port = port(forPeer: peer) else {
        core.countUnaddressable()
        continue
      }
      deliver(count: count, from: port)
    }
  }

  private func receive(on fd: Int32, port: PortID) {
    for _ in 0..<Self.batch {
      let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
      guard count >= 0 else {
        if errno != EAGAIN && errno != EWOULDBLOCK { removePort(port) }
        return
      }
      deliver(count: count, from: port)
    }
  }

  /// The port for a sender address, creating a socket connected back to it on first sight.
  private func port(forPeer peer: String) -> PortID? {
    guard !peer.isEmpty else { return nil }
    if let port = portsByPeer[peer] { return port }
    guard let fd = try? UnixSocket.make(SOCK_DGRAM) else { return nil }
    do {
      try UnixSocket.connect(fd, path: peer)
    } catch {
      close(fd)
      return nil
    }
    UnixSocket.setNonBlocking(fd)
    UnixSocket.setBuffer(fd, option: SO_SNDBUF, bytes: Self.socketBuffer)
    return addPort(Port(fd: fd, peer: peer))
  }

  @discardableResult private func addPort(_ port: Port) -> PortID {
    let id = nextPort
    nextPort += 1
    ports[id] = port
    if let peer = port.peer { portsByPeer[peer] = id }
    core.addPort(id)
    return id
  }

  private func removePort(_ id: PortID) {
    guard let port = ports.removeValue(forKey: id) else { return }
    if let peer = port.peer { portsByPeer[peer] = nil }
    close(port.fd)
    core.removePort(id)
  }

  private func deliver(count: Int, from port: PortID) {
    let now = ProcessInfo.processInfo.systemUptime
    guard case .deliver(let targets) = core.forward(buffer[..<count], from: port, now: now) else {
      return
    }
    for target in targets {
      guard let fd = ports[target]?.fd else { continue }
      let sent = buffer.withUnsafeBytes { send(fd, $0.baseAddress, count, MSG_DONTWAIT) }
      guard sent < 0 else { continue }
      switch errno {
      case ECONNREFUSED, ENOENT, ENOTCONN, ECONNRESET, EPIPE, EBADF:
        removePort(target)
      default:
        core.countCongested()
      }
    }
  }

  private func serveStats() {
    while true {
      let client = accept(statsFD, nil, nil)
      guard client >= 0 else { return }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      if var data = try? encoder.encode(core.stats) {
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
      }
      close(client)
    }
  }

  private func cleanup() {
    let alreadyClosed = lock.withLock {
      defer { closed = true }
      return closed
    }
    guard !alreadyClosed else { return }
    for port in ports.values { close(port.fd) }
    ports = [:]
    for fd in [dataFD, statsFD, wakeRead, wakeWrite] { close(fd) }
    unlink(paths.switchSocket.path)
    unlink(paths.statsSocket.path)
    unlink(paths.pidFile.path)
  }
}
