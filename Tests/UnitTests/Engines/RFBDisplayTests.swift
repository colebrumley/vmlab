import Foundation
import Testing
import VMLabCore
import VMLabRFB

@testable import VMLabEngines

/// `RFBDisplaySession`, Core's `DisplaySession` over a recorded QEMU RFB stream (R-502).
@Suite struct RFBDisplayTests {
  static let endpoint = DisplayEndpoint(address: .unixSocket(path: "/tmp/v.sock"), hostSide: true)

  static func session() async throws -> (RFBDisplaySession, ReplayTransport, Int) {
    let transport = ReplayTransport(serverBytes: try rfbFixture("qemu-ramfb-640x480.bin"))
    let client = try await RFBClient.handshake(over: transport)
    try await client.processNextMessage()
    return (
      RFBDisplaySession(client: client, endpoint: endpoint), transport,
      await transport.written.count
    )
  }

  @Test func screenshotScalesAndDiffs() async throws {
    let (session, _, _) = try await Self.session()
    #expect(try await session.screenSize() == (640, 480))
    let first = try await session.screenshot(ScreenshotRequest(maxEdge: 320))
    #expect(first.width == 640 && first.height == 480 && first.scale == 0.5)
    #expect(first.mimeType == "image/png")
    #expect(first.image?.starts(with: [0x89, 0x50, 0x4e, 0x47]) == true)
    let again = try await session.screenshot(ScreenshotRequest(diffFrom: first.id))
    #expect(again.unchanged && again.image == nil)
    let error = await #expect(throws: VMLabError.self) {
      try await session.screenshot(ScreenshotRequest(diffFrom: "nope"))
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("diffFrom"))
  }

  @Test func inputBecomesRFBEvents() async throws {
    let (session, transport, start) = try await Self.session()
    try await session.pointer(x: 640, y: 480, buttons: [.left, .right])
    try await session.press("Return")
    #expect(
      Array(await transport.written[start...])
        == [5, 5, 0x02, 0x80, 0x01, 0xe0] + [4, 1, 0, 0, 0, 0, 0xff, 0x0d]
        + [4, 0, 0, 0, 0, 0, 0xff, 0x0d])
    let error = await #expect(throws: VMLabError.self) { try await session.press("ctrl+nokey") }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("text"))
  }

  /// A uniform first frame (macOS Screen Sharing's black opener) is detected.
  @Test func uniformFramesAreDetected() {
    #expect(RFBDisplaySession.isUniform(Framebuffer(width: 64, height: 64).pixels))
    var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
    #expect(RFBDisplaySession.isUniform(pixels))
    pixels[4 * 31 * 9 + 1] = 200
    #expect(!RFBDisplaySession.isUniform(pixels))
  }

  @Test func unreachableDisplayIsGuestUnreachable() async {
    let connector = RFBDisplayConnector(firstFrameTimeout: .milliseconds(100))
    let error = await #expect(throws: VMLabError.self) {
      try await connector.connect(
        DisplayEndpoint(address: .unixSocket(path: "/tmp/vmlab-no-such.sock"), hostSide: true))
    }
    #expect(error?.code == .guestUnreachable)
  }

  @Test func missingPasswordFileIsGuestUnreachable() async {
    let connector = RFBDisplayConnector()
    let error = await #expect(throws: VMLabError.self) {
      try await connector.connect(
        DisplayEndpoint(
          address: .tcp(host: "127.0.0.1", port: 1), auth: .vncPassword(file: "/nonexistent/p"),
          hostSide: false))
    }
    #expect(error?.code == .guestUnreachable)
  }
}

@Suite struct RFBDeadPeerMappingTests {
  @Test func onlyTheEnginesOwnDisplayIsADeadPeer() {
    let host = DisplayEndpoint(address: .unixSocket(path: "/v/vnc.sock"), hostSide: true)
    let guest = DisplayEndpoint(
      address: .tcp(host: "192.168.64.5", port: 5900), auth: .none, hostSide: false)
    let hostError = RFBDisplaySession.map(RFBError.deadPeer("silent"), endpoint: host)
    #expect(DeadPeer.isDeadPeer(hostError))
    #expect(hostError.data["channel"] == .string("display"))
    let guestError = RFBDisplaySession.map(RFBError.deadPeer("silent"), endpoint: guest)
    #expect(guestError.code == .guestUnreachable)
    #expect(!DeadPeer.isDeadPeer(guestError))
  }
}
