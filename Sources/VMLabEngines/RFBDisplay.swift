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
      await fresh.start(deadPeerWindow: DeadPeer.window)
      try await fresh.waitForUpdateCount(1, timeout: firstFrameTimeout)
    } catch {
      throw Self.map(error, endpoint: endpoint)
    }
    client = fresh
    return fresh
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

  public func pointer(x: Int, y: Int, buttons: DisplayButtons) async throws(VMLabError) {
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
    try await run { try await $0.press(parsed) }
  }

  public func type(_ text: String) async throws(VMLabError) {
    try await run { try await $0.type(text) }
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
    case .deadPeer(let reason):
      // QEMU's own VNC socket going silent means QEMU is hung (the VM is marked broken); an
      // in-guest VNC server going silent says nothing about the engine.
      if endpoint.hostSide {
        return DeadPeer.error(channel: "display", endpoint: address, reason: reason)
      }
      return VMLabError(
        code: .guestUnreachable, message: "The display at \(address) stopped answering: \(reason)",
        hint: "The guest's VNC server may be hung or restarting; retry, or check vm_serial.",
        data: [
          "channel": .string("display"), "address": .string(address), "reason": .string(reason),
        ])
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
