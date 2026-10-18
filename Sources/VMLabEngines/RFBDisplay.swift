import Foundation
import VMLabCore
import VMLabRFB

/// Core's `DisplayConnector` over VMLabRFB: every display endpoint (QEMU's VNC socket, an
/// in-guest VNC server, Screen Sharing) speaks RFB.
public struct RFBDisplayConnector: DisplayConnector {
  /// How long a new connection waits for its first framebuffer update.
  public var firstFrameTimeout: Duration

  public init(firstFrameTimeout: Duration = .seconds(10)) {
    self.firstFrameTimeout = firstFrameTimeout
  }

  public func connect(_ endpoint: DisplayEndpoint) async throws(VMLabError)
    -> any DisplaySession
  {
    let session = RFBDisplaySession(endpoint: endpoint, firstFrameTimeout: firstFrameTimeout)
    try await session.reconnectIfNeeded()
    return session
  }
}

/// One guest display over RFB, with the screenshot cache `diffFrom` names. When the connection
/// drops (the guest rebooted its VNC server, QEMU restarted), the next call reconnects once; the
/// cache survives, so earlier screenshot ids stay valid.
public actor RFBDisplaySession: DisplaySession {
  public let endpoint: DisplayEndpoint
  let firstFrameTimeout: Duration
  private var client: RFBClient?
  /// When the current connection was made.
  private var connectedAt = ContinuousClock.now
  private var cache = ScreenshotCache()

  public init(endpoint: DisplayEndpoint, firstFrameTimeout: Duration = .seconds(10)) {
    self.endpoint = endpoint
    self.firstFrameTimeout = firstFrameTimeout
  }

  /// A session over an already connected client (tests drive it with a scripted transport).
  init(client: RFBClient, endpoint: DisplayEndpoint) {
    self.endpoint = endpoint
    self.firstFrameTimeout = .seconds(10)
    self.client = client
  }

  /// The connected client, connecting (and waiting for the first frame) when there is none or the
  /// last one failed.
  @discardableResult
  func reconnectIfNeeded() async throws(VMLabError) -> RFBClient {
    if let client, await client.loopError == nil { return client }
    if let client { await client.close() }
    client = nil
    let fresh: RFBClient
    do {
      fresh = try await RFBClient.connect(Self.rfbEndpoint(endpoint), password: try password())
      await fresh.start()
      try await fresh.waitForUpdateCount(1, timeout: firstFrameTimeout)
      // macOS Screen Sharing answers the first request with an all-black frame and sends the
      // screen a moment later; give a uniform first frame a few more updates to fill in.
      var updates = await fresh.updateCount
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: Self.uniformFrameGrace)
      while Self.isUniform(await fresh.framebuffer.pixels), clock.now < deadline {
        updates += 1
        try? await fresh.waitForUpdateCount(updates, timeout: .milliseconds(500))
      }
    } catch {
      throw Self.map(error, endpoint: endpoint)
    }
    client = fresh
    connectedAt = .now
    inputReady = nil
    return fresh
  }

  /// The pause between key events: macOS Screen Sharing drops a stroke whose press and release
  /// arrive in one burst (QEMU's VNC does not mind).
  static let keyHold = Duration.milliseconds(20)

  /// How long a new connection waits for a uniform first frame to change.
  static let uniformFrameGrace = Duration.seconds(3)

  /// Whether every sampled pixel of 32-bit `pixels` has the same colour.
  static func isUniform(_ pixels: [UInt8]) -> Bool {
    guard pixels.count >= 4 else { return true }
    let first = (pixels[0], pixels[1], pixels[2])
    var index = 0
    while index + 2 < pixels.count {
      if (pixels[index], pixels[index + 1], pixels[index + 2]) != first { return false }
      index += 4 * 31
    }
    return true
  }

  private func run<T: Sendable>(_ body: (RFBClient) async throws -> T) async throws(VMLabError)
    -> T
  {
    let client = try await reconnectIfNeeded()
    do {
      return try await body(client)
    } catch {
      throw Self.map(error, endpoint: endpoint)
    }
  }

  public func screenSize() async throws(VMLabError) -> (width: Int, height: Int) {
    let framebuffer = try await run { await $0.framebuffer }
    return (framebuffer.width, framebuffer.height)
  }

  public func screenshot(_ request: ScreenshotRequest) async throws(VMLabError) -> ScreenCapture {
    let framebuffer = try await run { await $0.framebuffer }
    let options = ScreenshotOptions(
      format: request.format == .png ? .png : .jpeg, quality: request.quality,
      maxEdge: request.maxEdge,
      region: request.region.map {
        PixelRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
      })
    let shot: Screenshot
    do {
      shot = try cache.capture(framebuffer, options: options, diffFrom: request.diffFrom)
    } catch {
      throw Self.map(error, endpoint: endpoint)
    }
    return ScreenCapture(
      id: shot.id, width: shot.width, height: shot.height, scale: shot.scale,
      image: shot.image?.data, mimeType: shot.image?.mimeType,
      changedRegion: shot.changedRegion.map {
        DisplayRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
      }, unchanged: shot.unchanged)
  }

  /// When input may be sent on the current connection: macOS Screen Sharing ignores key events
  /// for a moment after a viewer connects ("ignore key event" in its log).
  private var inputReady: ContinuousClock.Instant?

  /// The quiet period after connecting to macOS Screen Sharing before input is sent.
  static let screenSharingWarmup = Duration.seconds(3)
  static let screenSharingVersion = "RFB 003.889"

  /// Waits out the warm-up of a fresh Screen Sharing connection.
  private func awaitInputReady() async throws(VMLabError) {
    let client = try await reconnectIfNeeded()
    if inputReady == nil {
      let warmup =
        client.serverVersion == Self.screenSharingVersion ? Self.screenSharingWarmup : .zero
      inputReady = connectedAt.advanced(by: warmup)
    }
    if let inputReady, inputReady > .now { try? await Task.sleep(until: inputReady) }
  }

  public func pointer(x: Int, y: Int, buttons: DisplayButtons) async throws(VMLabError) {
    try await awaitInputReady()
    try await run {
      try await $0.pointer(x: x, y: y, buttons: PointerButtons(rawValue: buttons.rawValue))
    }
  }

  public func press(_ chord: String) async throws(VMLabError) {
    let parsed: KeyChord
    do {
      parsed = try KeyChord(parsing: chord)
    } catch {
      throw Self.map(error, endpoint: endpoint)
    }
    try await awaitInputReady()
    try await run { try await $0.press(parsed, hold: Self.keyHold) }
  }

  public func type(_ text: String) async throws(VMLabError) {
    try await awaitInputReady()
    try await run { try await $0.type(text, gap: Self.keyHold, hold: Self.keyHold) }
  }

  public func close() async {
    await client?.close()
    client = nil
  }

  // MARK: Helpers

  static func rfbEndpoint(_ endpoint: DisplayEndpoint) throws -> RFBEndpoint {
    switch endpoint.address {
    case .unixSocket(let path): return .unix(path: path)
    case .tcp(let host, let port):
      guard let port = UInt16(exactly: port) else {
        throw RFBError.connectFailed("port \(port) out of range")
      }
      return .tcp(host: host, port: port)
    }
  }

  /// The VNC password from the endpoint's password file (first line), or nil for `none`.
  private func password() throws(VMLabError) -> String? {
    guard case .vncPassword(let file) = endpoint.auth else { return nil }
    do {
      let text = try String(contentsOfFile: file, encoding: .utf8)
      return String(text.split(whereSeparator: \.isNewline).first ?? "")
    } catch {
      throw VMLabError(
        code: .guestUnreachable, message: "Cannot read the VNC password file \(file)",
        hint: "The guest's VNC server was provisioned with it; recreate the VM if it is gone.",
        data: ["file": .string(file), "channel": .string("display")])
    }
  }

  /// RFB failures as Appendix D codes: bad requests are `invalid_request`, a display that cannot
  /// be reached `guest_unreachable`, protocol trouble `engine_error`.
  static func map(_ error: any Error, endpoint: DisplayEndpoint) -> VMLabError {
    if let error = error as? VMLabError { return error }
    let address =
      switch endpoint.address {
      case .unixSocket(let path): "unix:\(path)"
      case .tcp(let host, let port): "\(host):\(port)"
      }
    guard let rfb = error as? RFBError else {
      return VMLabError(
        code: .engineError, message: "The display failed: \(error)",
        hint: "Retry; vm_inspect shows the display endpoint.",
        data: ["engine": .string("rfb"), "raw": .string("\(error)")])
    }
    switch rfb {
    case .invalidScreenshotRequest(let field, let reason):
      return .invalidRequest(
        field: field, reason: "\(field) \(reason)", hint: "Fix \(field) and retry.")
    case .unknownKey(let key):
      return .invalidRequest(
        field: "text", reason: "\(key) is not a key name",
        hint: "Use xdotool names such as Return, Tab, Escape, ctrl+c, cmd+space, F5.")
    case .connectFailed, .connectionClosed, .connectionRefused, .timeout:
      return VMLabError(
        code: .guestUnreachable, message: "The display at \(address) is not reachable: \(rfb)",
        hint: endpoint.hostSide
          ? "The guest may be restarting; retry in a moment."
          : "The guest's VNC server may not be up yet (the desktop installs on first boot); "
            + "retry in a minute.",
        data: ["channel": .string("display"), "address": .string(address)])
    case .passwordRequired, .authenticationFailed:
      return VMLabError(
        code: .guestUnreachable, message: "The display at \(address) refused the VNC password",
        hint: "The guest's VNC password no longer matches <vm>/vnc.pass; recreate the VM.",
        data: ["channel": .string("display"), "address": .string(address)])
    case .unsupportedVersion, .noSupportedSecurityType, .protocolViolation, .emptyFramebuffer:
      return VMLabError(
        code: .engineError, message: "The display at \(address) failed: \(rfb)",
        hint: "Retry; if it persists the guest's VNC server speaks something vmlab cannot.",
        data: ["engine": .string("rfb"), "raw": .string("\(rfb)")])
    }
  }
}
