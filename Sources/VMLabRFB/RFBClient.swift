import CoreGraphics
import Foundation
import Synchronization
import VMLabCore

/// An RFB 3.8 client that keeps a `Framebuffer` current with incremental update requests.
///
/// `connect` performs the handshake (security None or VNC Authentication, shared `ClientInit`),
/// sets the pixel format to BGRX and requests Raw, CopyRect and DesktopSize. `start()` runs the
/// update loop in the background; `snapshot()` returns the current screen at any time.
public actor RFBClient {
  /// RFB encoding numbers this client requests.
  public enum Encoding: Int32, Sendable {
    case raw = 0
    case copyRect = 1
    case desktopSize = -223
  }

  /// A decoded server-to-client message.
  public enum ServerMessage: Equatable, Sendable {
    case framebufferUpdate(rectangles: Int)
    case setColourMapEntries
    case bell
    case serverCutText(String)
  }

  public let transport: any RFBTransport
  /// The desktop name from `ServerInit`.
  public let desktopName: String
  /// The pixel format the server announced in `ServerInit`, before ours replaced it.
  public let serverPixelFormat: PixelFormat
  public private(set) var framebuffer: Framebuffer
  /// Framebuffer updates applied so far.
  public private(set) var updateCount = 0
  /// Why the update loop stopped, if it did.
  public private(set) var loopError: RFBError?

  private var needsFullUpdate = true
  private var loopTask: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  /// When the server last sent bytes and whether it owes an update (R-1101).
  nonisolated let peer = PeerClock()
  private var waiters: [(id: Int, target: Int, cont: CheckedContinuation<Void, Error>)] = []
  private var nextWaiterID = 0

  /// Connects to `endpoint` and completes the handshake. Call `start()` to begin receiving updates.
  /// A server that accepts the connection but does not finish the handshake within
  /// `handshakeTimeout` (the dead-peer window, R-1101) fails with `deadPeer`.
  public static func connect(
    _ endpoint: RFBEndpoint, password: String? = nil,
    handshakeTimeout: Duration = DeadPeer.window
  ) async throws -> RFBClient {
    let transport = try await SocketTransport.connect(endpoint)
    return try await handshake(over: transport, password: password, timeout: handshakeTimeout)
  }

  /// `handshake(over:password:)` bounded by `timeout`: when it passes, the transport is closed
  /// (failing the pending read) and the error is `deadPeer`.
  public static func handshake(
    over transport: any RFBTransport, password: String? = nil, timeout: Duration
  ) async throws -> RFBClient {
    let expired = ExpiryFlag()
    let timer = Task {
      try await Task.sleep(for: timeout)
      expired.set()
      await transport.close()
    }
    defer { timer.cancel() }
    do {
      return try await handshake(over: transport, password: password)
    } catch {
      await transport.close()
      if expired.isSet {
        throw RFBError.deadPeer(DeadPeer.silence(timeout, waitingFor: "the RFB handshake"))
      }
      throw error
    }
  }

  /// Runs the RFB 3.8 handshake over `transport`, then sends `SetPixelFormat` and `SetEncodings`.
  public static func handshake(over transport: any RFBTransport, password: String? = nil)
    async throws -> RFBClient
  {
    let io = Reader(transport)
    // ProtocolVersion.
    let versionBytes = try await io.bytes(12)
    let version = String(decoding: versionBytes, as: UTF8.self)
    guard versionBytes.count == 12, version.hasPrefix("RFB "), version.hasSuffix("\n"),
      let major = Int(version.dropFirst(4).prefix(3)),
      let minor = Int(version.dropFirst(8).prefix(3)),
      major > 3 || (major == 3 && minor >= 8)
    else { throw RFBError.unsupportedVersion(version.trimmingCharacters(in: .newlines)) }
    try await transport.write(Array("RFB 003.008\n".utf8))

    // Security.
    let count = try await io.u8()
    if count == 0 { throw RFBError.connectionRefused(try await io.reasonString()) }
    let offered = try await io.bytes(Int(count))
    let chosen: UInt8
    if password != nil && offered.contains(2) {
      chosen = 2
    } else if offered.contains(1) {
      chosen = 1
    } else if offered.contains(2) {
      throw RFBError.passwordRequired
    } else {
      throw RFBError.noSupportedSecurityType(offered)
    }
    try await transport.write([chosen])
    if chosen == 2 {
      let challenge = try await io.bytes(16)
      try await transport.write(try VNCAuth.response(challenge: challenge, password: password!))
    }
    let result = try await io.u32()
    if result != 0 { throw RFBError.authenticationFailed(try await io.reasonString()) }

    // ClientInit (shared) and ServerInit.
    try await transport.write([1])
    let width = Int(try await io.u16())
    let height = Int(try await io.u16())
    let format = PixelFormat(bytes: try await io.bytes(16))
    let nameLength = Int(try await io.u32())
    guard nameLength <= 1 << 16 else {
      throw RFBError.protocolViolation("desktop name of \(nameLength) bytes")
    }
    let name = String(decoding: try await io.bytes(nameLength), as: UTF8.self)
    guard width <= Framebuffer.maxEdge, height <= Framebuffer.maxEdge else {
      throw RFBError.protocolViolation("framebuffer \(width)x\(height) too large")
    }

    let client = RFBClient(
      transport: transport, name: name, format: format, width: width, height: height)
    try await client.sendSetup()
    return client
  }

  private init(
    transport: any RFBTransport, name: String, format: PixelFormat, width: Int, height: Int
  ) {
    self.transport = transport
    desktopName = name
    serverPixelFormat = format
    framebuffer = Framebuffer(width: width, height: height)
  }

  private func sendSetup() async throws {
    try await transport.write([0, 0, 0, 0] + PixelFormat.bgrx.bytes)
    let encodings: [Encoding] = [.raw, .copyRect, .desktopSize]
    var message: [UInt8] = [2, 0] + be16(encodings.count)
    for e in encodings { message += be32(UInt32(bitPattern: e.rawValue)) }
    try await transport.write(message)
  }

  /// Sends a `FramebufferUpdateRequest` for the whole screen.
  public func requestUpdate(incremental: Bool) async throws {
    let message: [UInt8] =
      [3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(framebuffer.width)
      + be16(framebuffer.height)
    try await transport.write(message)
  }

  /// Starts the background loop: request, apply the update, request again (incrementally unless
  /// the desktop was resized). Stops on the first error, recorded in `loopError`.
  ///
  /// With `deadPeerWindow` (R-1101) a watchdog runs too: a server that has sent nothing for
  /// `probeInterval` is sent a non-incremental request for one pixel, which it must answer even
  /// when the screen is still; one that then stays silent for `deadPeerWindow` is dead, and the
  /// loop stops with `deadPeer`.
  public func start(
    deadPeerWindow: Duration? = nil, probeInterval: Duration = DeadPeer.probeInterval
  ) {
    guard loopTask == nil else { return }
    peer.received()
    loopTask = Task { await self.runLoop() }
    guard let window = deadPeerWindow else { return }
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: probeInterval) } catch { return }
        guard let self, await self.checkPeer(window: window, interval: probeInterval) else {
          return
        }
      }
    }
  }

  /// One watchdog tick; false once the loop is over.
  private func checkPeer(window: Duration, interval: Duration) async -> Bool {
    guard loopError == nil else { return false }
    if let reason = peer.overdue(window: window) {
      fail(.deadPeer(reason))
      loopTask?.cancel()
      await transport.close()
      return false
    }
    if !peer.isOwed, peer.idle() >= interval, framebuffer.width > 0, framebuffer.height > 0 {
      peer.awaiting("a forced framebuffer update")
      let probe: [UInt8] = [3, 0] + be16(0) + be16(0) + be16(1) + be16(1)
      do { try await transport.write(probe) } catch {
        fail(.connectionClosed)
        return false
      }
    }
    return true
  }

  /// Stops the loop and closes the connection.
  public func close() async {
    loopTask?.cancel()
    watchdog?.cancel()
    await transport.close()
    fail(.connectionClosed)
  }

  private func runLoop() async {
    do {
      try await requestUpdate(incremental: false)
      needsFullUpdate = false
      while !Task.isCancelled {
        let message = try await processNextMessage()
        guard case .framebufferUpdate(let rectangles) = message else { continue }
        if rectangles == 0 && !needsFullUpdate { try await Task.sleep(for: .milliseconds(16)) }
        let incremental = !needsFullUpdate
        needsFullUpdate = false
        try await requestUpdate(incremental: incremental)
      }
    } catch let error as RFBError {
      fail(error)
    } catch {
      fail(.connectionClosed)
    }
  }

  private func fail(_ error: RFBError) {
    if loopError == nil { loopError = error }
    let pending = waiters
    waiters = []
    for w in pending { w.cont.resume(throwing: error) }
  }

  /// Waits until `updateCount` exceeds its current value.
  public func waitForUpdate(timeout: Duration = .seconds(10)) async throws {
    try await waitForUpdateCount(updateCount + 1, timeout: timeout)
  }

  /// Waits until `updateCount` reaches `target`.
  public func waitForUpdateCount(_ target: Int, timeout: Duration = .seconds(10)) async throws {
    if updateCount >= target { return }
    if let loopError { throw loopError }
    let id = nextWaiterID
    nextWaiterID += 1
    let timer = Task {
      try await Task.sleep(for: timeout)
      self.timeOut(id)
    }
    defer { timer.cancel() }
    try await withCheckedThrowingContinuation { cont in waiters.append((id, target, cont)) }
  }

  private func timeOut(_ id: Int) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).cont.resume(throwing: RFBError.timeout)
  }

  /// The current screen.
  public func snapshot() throws -> CGImage { try framebuffer.cgImage() }

  private enum Pending {
    case raw(x: Int, y: Int, w: Int, h: Int, data: [UInt8])
    case copy(srcX: Int, srcY: Int, x: Int, y: Int, w: Int, h: Int)
    case resize(w: Int, h: Int)
  }

  /// Reads and applies one server message. A framebuffer update is applied atomically, after all
  /// its rectangles have arrived, so `snapshot()` never sees half of one.
  @discardableResult
  public func processNextMessage() async throws -> ServerMessage {
    let io = Reader(transport, peer: peer)
    let type = try await io.u8()
    switch type {
    case 0:
      _ = try await io.bytes(1)
      let count = Int(try await io.u16())
      var ops: [Pending] = []
      // Bounds are checked against the size the framebuffer will have when the op is applied.
      var width = framebuffer.width
      var height = framebuffer.height
      func inside(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        x + w <= width && y + h <= height
      }
      for _ in 0..<count {
        let x = Int(try await io.u16())
        let y = Int(try await io.u16())
        let w = Int(try await io.u16())
        let h = Int(try await io.u16())
        let encoding = Int32(bitPattern: try await io.u32())
        switch Encoding(rawValue: encoding) {
        case .raw:
          guard inside(x, y, w, h) else { throw outOfBounds("Raw", x, y, w, h, width, height) }
          ops.append(.raw(x: x, y: y, w: w, h: h, data: try await io.bytes(w * h * 4)))
        case .copyRect:
          let srcX = Int(try await io.u16())
          let srcY = Int(try await io.u16())
          guard inside(x, y, w, h), inside(srcX, srcY, w, h) else {
            throw outOfBounds("CopyRect", x, y, w, h, width, height)
          }
          ops.append(.copy(srcX: srcX, srcY: srcY, x: x, y: y, w: w, h: h))
        case .desktopSize:
          guard w > 0, h > 0, w <= Framebuffer.maxEdge, h <= Framebuffer.maxEdge else {
            throw RFBError.protocolViolation("DesktopSize \(w)x\(h)")
          }
          width = w
          height = h
          ops.append(.resize(w: w, h: h))
        case nil:
          throw RFBError.protocolViolation("unrequested encoding \(encoding)")
        }
      }
      for op in ops {
        switch op {
        case .raw(let x, let y, let w, let h, let data):
          framebuffer.applyRaw(x: x, y: y, width: w, height: h, data: data)
        case .copy(let srcX, let srcY, let x, let y, let w, let h):
          framebuffer.copyRect(srcX: srcX, srcY: srcY, x: x, y: y, width: w, height: h)
        case .resize(let w, let h):
          framebuffer.resize(width: w, height: h)
          needsFullUpdate = true
        }
      }
      updateCount += 1
      let ready = waiters.filter { $0.target <= updateCount }
      waiters.removeAll { $0.target <= updateCount }
      for w in ready { w.cont.resume() }
      return .framebufferUpdate(rectangles: count)
    case 1:
      _ = try await io.bytes(3)
      let colours = Int(try await io.u16())
      _ = try await io.bytes(colours * 6)
      return .setColourMapEntries
    case 2:
      return .bell
    case 3:
      _ = try await io.bytes(3)
      let length = Int(try await io.u32())
      guard length <= 1 << 24 else {
        throw RFBError.protocolViolation("cut text of \(length) bytes")
      }
      let text = try await io.bytes(length)
      return .serverCutText(String(decoding: text, as: UTF8.self))
    default:
      throw RFBError.protocolViolation("unknown server message type \(type)")
    }
  }

  private func outOfBounds(
    _ kind: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ width: Int, _ height: Int
  ) -> RFBError {
    .protocolViolation("\(kind) rectangle \(w)x\(h)+\(x)+\(y) outside \(width)x\(height)")
  }
}

/// Big-endian field reads over a transport.
private struct Reader {
  let transport: any RFBTransport
  let peer: PeerClock?
  init(_ transport: any RFBTransport, peer: PeerClock? = nil) {
    self.transport = transport
    self.peer = peer
  }

  func bytes(_ n: Int) async throws -> [UInt8] {
    let bytes = try await transport.read(exactly: n)
    peer?.received()
    return bytes
  }
  func u8() async throws -> UInt8 { try await bytes(1)[0] }
  func u16() async throws -> UInt16 {
    let b = try await bytes(2)
    return UInt16(b[0]) << 8 | UInt16(b[1])
  }
  func u32() async throws -> UInt32 {
    let b = try await bytes(4)
    return b.reduce(0) { $0 << 8 | UInt32($1) }
  }
  /// A u32 length followed by that many bytes of text (a failure reason).
  func reasonString() async throws -> String {
    let length = Int(try await u32())
    guard length <= 1 << 16 else { throw RFBError.protocolViolation("reason of \(length) bytes") }
    return String(decoding: try await bytes(length), as: UTF8.self)
  }
}

private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
private func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (24 - 8 * $0)) & 0xff) } }

/// Set once, read from anywhere: whether a timer fired.
final class ExpiryFlag: Sendable {
  private let flag = Mutex(false)
  func set() { flag.withLock { $0 = true } }
  var isSet: Bool { flag.withLock { $0 } }
}
