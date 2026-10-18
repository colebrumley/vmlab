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
  private let attachFD: Int32
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
    _ = try UnixSocket.address(paths.attachSocket.path)
    try fm.createDirectory(at: paths.portsDirectory, withIntermediateDirectories: true)
    if let text = try? String(contentsOf: paths.pidFile, encoding: .utf8),
      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
      kill(pid, 0) == 0 || errno == EPERM
    {
      throw SwitchError.alreadyRunning(pid: pid)
    }
    unlink(paths.switchSocket.path)
    unlink(paths.statsSocket.path)
    unlink(paths.attachSocket.path)

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

      let attach = try UnixSocket.make(SOCK_STREAM)
      fds.append(attach)
      try UnixSocket.bind(attach, path: paths.attachSocket.path)
      guard listen(attach, 16) == 0 else { throw SwitchError.system(call: "listen", errno: errno) }
      UnixSocket.setNonBlocking(attach)

      var pipeFDs: [Int32] = [0, 0]
      guard pipe(&pipeFDs) == 0 else { throw SwitchError.system(call: "pipe", errno: errno) }
      fds += pipeFDs
      UnixSocket.setNonBlocking(pipeFDs[0])
      UnixSocket.setNonBlocking(pipeFDs[1])

      try "\(getpid())\n".write(to: paths.pidFile, atomically: true, encoding: .utf8)
      (dataFD, statsFD, attachFD, wakeRead, wakeWrite) = (
        data, stats, attach, pipeFDs[0], pipeFDs[1]
      )
    } catch {
      for fd in fds { close(fd) }
      unlink(paths.switchSocket.path)
      unlink(paths.statsSocket.path)
      unlink(paths.attachSocket.path)
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
  /// owns `fd` from now on, and closes it at once if it has already stopped.
  public func attach(fd: Int32) {
    let accepted = lock.withLock {
      if !closed { pending.append(fd) }
      return !closed
    }
    if accepted { wake() } else { close(fd) }
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
      var fds = [wakeRead, dataFD, statsFD, attachFD].map {
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
      if fds[3].revents & Int16(POLLIN) != 0 { acceptAttachments() }
      for (index, (port, fd)) in readable.enumerated() {
        // A delivery earlier in this pass may have removed the port and closed its fd, and another
        // thread may since have been given that number: never touch an fd the port no longer owns.
        guard ports[port]?.fd == fd else { continue }
        let events = fds[4 + index].revents
        if events & Int16(POLLIN) != 0 {
          receive(on: fd, port: port)
        } else if events & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
          removePort(port)
        }
      }
    }
    cleanup()
  }

  /// Under the lock, and never after `cleanup()`: a closed `wakeWrite` number may already belong
  /// to another socket or pipe in this process.
  private func wake() {
    lock.withLock {
      guard !closed else { return }
      var byte: UInt8 = 1
      _ = write(wakeWrite, &byte, 1)
    }
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
      // macOS reports a closed peer once, as ECONNRESET; later sends on the now unconnected
      // socket fail with EDESTADDRREQ.
      case ECONNREFUSED, ENOENT, ENOTCONN, ECONNRESET, EPIPE, EBADF, EDESTADDRREQ:
        removePort(target)
      default:
        core.countCongested()
      }
    }
  }

  /// Each connection to `attach.sock` carries one datagram socket (`SCM_RIGHTS`) that becomes a
  /// port, answered with `ok`; a connection that sends none within a second is dropped.
  private func acceptAttachments() {
    while true {
      let client = accept(attachFD, nil, nil)
      guard client >= 0 else { return }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      let flags = fcntl(client, F_GETFL)
      _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
      var timeout = timeval(tv_sec: 1, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      if let fd = try? UnixSocket.receiveDescriptor(from: client), fd >= 0 {
        UnixSocket.setNonBlocking(fd)
        UnixSocket.setBuffer(fd, option: SO_RCVBUF, bytes: Self.socketBuffer)
        UnixSocket.setBuffer(fd, option: SO_SNDBUF, bytes: Self.socketBuffer)
        addPort(Port(fd: fd, peer: nil))
        _ = "ok\n".withCString { write(client, $0, 3) }
      }
      close(client)
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
    // Marking closed and closing the pipe under one lock keeps `wake()` off a reused number; fds
    // attached after `run()` last looked are closed here, so every fd is closed exactly once.
    let (alreadyClosed, attached) = lock.withLock {
      defer {
        closed = true
        pending = []
      }
      if !closed { close(wakeWrite) }
      return (closed, pending)
    }
    guard !alreadyClosed else { return }
    for fd in attached { close(fd) }
    for port in ports.values { close(port.fd) }
    ports = [:]
    for fd in [dataFD, statsFD, attachFD, wakeRead] { close(fd) }
    unlink(paths.switchSocket.path)
    unlink(paths.statsSocket.path)
    unlink(paths.attachSocket.path)
    unlink(paths.pidFile.path)
  }
}
