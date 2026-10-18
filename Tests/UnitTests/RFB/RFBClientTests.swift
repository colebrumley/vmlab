import CryptoKit
import Darwin
import Foundation
import Testing

@testable import VMLabRFB

func rfbFixture(_ name: String) throws -> [UInt8] {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../Fixtures/rfb/\(name)")
  return [UInt8](try Data(contentsOf: url))
}

func sha256(_ bytes: [UInt8]) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

@Suite struct RFBClientTests {
  /// Recorded from `qemu-system-aarch64 -M virt -device ramfb -vnc unix:… -S` (QEMU 10): the
  /// server half of a session whose client sent the same messages as `RFBClient`.
  @Test func qemuRecordingDecodesToExpectedImage() async throws {
    let transport = ReplayTransport(serverBytes: try rfbFixture("qemu-ramfb-640x480.bin"))
    let client = try await RFBClient.handshake(over: transport)
    #expect(await client.desktopName == "QEMU")
    let message = try await client.processNextMessage()
    #expect(message == .framebufferUpdate(rectangles: 1))
    #expect(await transport.atEnd)
    let fb = await client.framebuffer
    #expect(fb.width == 640 && fb.height == 480)
    #expect(sha256(fb.pixels) == "93ec0d171ed1c8fb106f37978ede1f72ae02eb51a2ba819719ba9d77b3eceb00")

    let image = try await client.snapshot()
    #expect(image.width == 640 && image.height == 480)
    let png = try Framebuffer.pngData(image)
    #expect(png.starts(with: [0x89, 0x50, 0x4e, 0x47]))
  }

  @Test func clientSendsVersionSecurityInitPixelFormatAndEncodings() async throws {
    let transport = ReplayTransport(serverBytes: try rfbFixture("qemu-ramfb-640x480.bin"))
    let client = try await RFBClient.handshake(over: transport)
    try await client.requestUpdate(incremental: false)
    let expected: [UInt8] =
      Array("RFB 003.008\n".utf8) + [1]  // version, security None
      + [1]  // ClientInit shared
      + [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]  // BGRX
      + [2, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, 0xff, 0xff, 0x21]  // Raw, CopyRect, DesktopSize
      + [3, 0, 0, 0, 0, 0, 0x02, 0x80, 0x01, 0xe0]  // full update request 640x480
    #expect(await transport.written == expected)
  }

  @Test func syntheticStreamWithAuthCopyRectAndResize() async throws {
    let transport = ReplayTransport(
      serverBytes: try rfbFixture("synthetic-auth-copyrect-resize.bin"))
    let client = try await RFBClient.handshake(over: transport, password: "secret")
    #expect(await client.desktopName == "synthetic")
    let written = await transport.written
    // Version, chosen type 2, then the DES response to "0123456789abcdef" under "secret".
    #expect(Array(written[12..<13]) == [2])
    #expect(Array(written[13..<29]) == hex("752440ee2bfcc2a0d9013fd20371e23b"))

    #expect(try await client.processNextMessage() == .framebufferUpdate(rectangles: 1))
    #expect(
      sha256(await client.framebuffer.pixels)
        == "f87b101a88535795b6fa36afb20c8c4d3d51fafb97027ea81a59fae077cacb70")
    #expect(try await client.processNextMessage() == .bell)
    #expect(try await client.processNextMessage() == .framebufferUpdate(rectangles: 2))
    #expect(
      sha256(await client.framebuffer.pixels)
        == "5ec986d6917b68dbe00a0238c487cca83268466d129a16763bbb16124f0cb891")
    #expect(try await client.processNextMessage() == .serverCutText("hello"))
    #expect(try await client.processNextMessage() == .framebufferUpdate(rectangles: 2))
    let fb = await client.framebuffer
    #expect(fb.width == 6 && fb.height == 2)
    #expect(sha256(fb.pixels) == "cce98608f5a448ddbb563ce64891178314ea226af2e133000b94b9689fd2c997")
    #expect(await client.updateCount == 3)
    #expect(await transport.atEnd)
  }

  @Test func vncAuthWithoutPasswordIsRefused() async throws {
    let transport = ReplayTransport(
      serverBytes: try rfbFixture("synthetic-auth-copyrect-resize.bin"))
    await #expect(throws: RFBError.passwordRequired) {
      _ = try await RFBClient.handshake(over: transport)
    }
  }

  @Test func oldVersionIsRefused() async throws {
    let transport = ReplayTransport(serverBytes: Array("RFB 003.003\n".utf8))
    await #expect(throws: RFBError.unsupportedVersion("RFB 003.003")) {
      _ = try await RFBClient.handshake(over: transport)
    }
  }

  @Test func failedAuthenticationCarriesReason() async throws {
    var bytes = Array("RFB 003.008\n".utf8) + [1, 2] + [UInt8](repeating: 7, count: 16)
    bytes += [0, 0, 0, 1, 0, 0, 0, 4] + Array("nope".utf8)
    let transport = ReplayTransport(serverBytes: bytes)
    await #expect(throws: RFBError.authenticationFailed("nope")) {
      _ = try await RFBClient.handshake(over: transport, password: "x")
    }
  }

  @Test func outOfBoundsRectangleIsAProtocolViolation() async throws {
    var bytes = Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0]
    bytes += [0, 2, 0, 2] + PixelFormat.bgrx.bytes + [0, 0, 0, 0]
    bytes += [0, 0, 0, 1, 0, 1, 0, 1, 0, 2, 0, 2, 0, 0, 0, 0]  // 2x2 Raw at (1,1) in a 2x2 screen
    let client = try await RFBClient.handshake(over: ReplayTransport(serverBytes: bytes))
    await #expect(throws: RFBError.self) { try await client.processNextMessage() }
  }

  /// The real socket transport and the background loop against a local unix-socket server.
  @Test func updateLoopOverUnixSocket() async throws {
    let fixture = try rfbFixture("qemu-ramfb-640x480.bin")
    let path = "/tmp/vmlab-rfb-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    let server = try OneShotServer(path: path, reply: fixture)
    defer { server.stop() }
    let client = try await RFBClient.connect(.unix(path: path))
    await client.start()
    try await client.waitForUpdateCount(1, timeout: .seconds(10))
    #expect(
      sha256(await client.framebuffer.pixels)
        == "93ec0d171ed1c8fb106f37978ede1f72ae02eb51a2ba819719ba9d77b3eceb00")
    await client.close()
    #expect(await client.loopError == .connectionClosed)
  }

  @Test func connectToMissingSocketFails() async {
    await #expect(throws: RFBError.self) {
      _ = try await RFBClient.connect(.unix(path: "/tmp/vmlab-rfb-missing-\(getpid()).sock"))
    }
  }
}

/// An in-guest VNC server is untrusted: its sizes and updates must not let it exhaust the host's
/// memory (a 16384² ServerInit was 1 GiB; every Raw rectangle of an update was buffered).
@Suite struct RFBClientLimitsTests {
  static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
  static func serverInit(_ w: Int, _ h: Int) -> [UInt8] {
    Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0] + be16(w) + be16(h)
      + PixelFormat.bgrx.bytes + [0, 0, 0, 0]
  }
  static func update(_ count: Int) -> [UInt8] { [0, 0] + be16(count) }
  static func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: Int32) -> [UInt8] {
    let e = UInt32(bitPattern: encoding)
    return be16(x) + be16(y) + be16(w) + be16(h)
      + [UInt8(e >> 24 & 0xff), UInt8(e >> 16 & 0xff), UInt8(e >> 8 & 0xff), UInt8(e & 0xff)]
  }

  static func isProtocolViolation(_ error: any Error) -> Bool {
    if case .protocolViolation = error as? RFBError { true } else { false }
  }

  @Test(arguments: [(16384, 16384), (8193, 1), (8192, 8192), (1, 65535)])
  func absurdServerInitIsRefused(_ size: (Int, Int)) async {
    let transport = ReplayTransport(serverBytes: Self.serverInit(size.0, size.1))
    await #expect {
      _ = try await RFBClient.handshake(over: transport)
    } throws: { Self.isProtocolViolation($0) }
  }

  @Test func eightKUltraHDIsAccepted() async throws {
    #expect(Framebuffer.accepts(width: 7680, height: 4320))
    #expect(Framebuffer.accepts(width: 8192, height: 4096))
    #expect(!Framebuffer.accepts(width: 8192, height: 4097))
    #expect(Framebuffer.accepts(width: 0, height: 0))
  }

  @Test(arguments: [(16384, 16384), (8192, 8192), (9000, 10), (0, 10)])
  func absurdDesktopSizeIsRefused(_ size: (Int, Int)) async throws {
    let bytes =
      Self.serverInit(2, 2) + Self.update(1) + Self.rect(0, 0, size.0, size.1, -223)
    let client = try await RFBClient.handshake(over: ReplayTransport(serverBytes: bytes))
    await #expect {
      try await client.processNextMessage()
    } throws: { Self.isProtocolViolation($0) }
    #expect(await client.framebuffer.width == 2)
  }

  /// A Raw rectangle larger than the read chunk is applied in pieces and lands intact.
  @Test func largeRawRectangleIsAppliedInPieces() async throws {
    let (w, h) = (700, 600)
    let pixels = (0..<(w * h * 4)).map { UInt8(truncatingIfNeeded: $0 &* 31 >> 3) }
    let bytes = Self.serverInit(w, h) + Self.update(1) + Self.rect(0, 0, w, h, 0) + pixels
    let transport = ReplayTransport(serverBytes: bytes)
    let client = try await RFBClient.handshake(over: transport)
    #expect(try await client.processNextMessage() == .framebufferUpdate(rectangles: 1))
    #expect(await client.framebuffer.pixels == pixels)
    #expect(await transport.atEnd)
  }

  /// Rectangles are applied to a working copy as they arrive; an update that fails part way
  /// leaves the screen as it was.
  @Test func aFailedUpdateLeavesTheScreenUnchanged() async throws {
    let bytes =
      Self.serverInit(2, 2) + Self.update(2) + Self.rect(0, 0, 2, 2, 0)
      + [UInt8](repeating: 0xaa, count: 16) + Self.rect(1, 1, 2, 2, 0)
    let client = try await RFBClient.handshake(over: ReplayTransport(serverBytes: bytes))
    await #expect(throws: RFBError.self) { try await client.processNextMessage() }
    #expect(await client.framebuffer.pixels == [UInt8](repeating: 0, count: 16))
    #expect(await client.updateCount == 0)
  }

  /// Rectangles after a DesktopSize in the same update are checked against the new size and
  /// applied to the new screen.
  @Test func resizeThenRawInOneUpdate() async throws {
    let bytes =
      Self.serverInit(2, 2) + Self.update(2) + Self.rect(0, 0, 3, 1, -223)
      + Self.rect(0, 0, 3, 1, 0) + [UInt8](repeating: 7, count: 12)
    let client = try await RFBClient.handshake(over: ReplayTransport(serverBytes: bytes))
    #expect(try await client.processNextMessage() == .framebufferUpdate(rectangles: 2))
    let fb = await client.framebuffer
    #expect(fb.width == 3 && fb.height == 1 && fb.pixels == [UInt8](repeating: 7, count: 12))
  }

  /// One update's Raw data may cover the screen a bounded number of times; past that it is a
  /// protocol violation, refused before the rectangle's bytes are read.
  @Test func rawBytesPerUpdateAreBounded() async throws {
    let cover = RFBClient.maxScreenCoveragePerUpdate
    var bytes = Self.serverInit(2, 2) + Self.update(cover + 1)
    for _ in 0..<cover { bytes += Self.rect(0, 0, 2, 2, 0) + [UInt8](repeating: 1, count: 16) }
    bytes += Self.rect(0, 0, 2, 2, 0)
    let client = try await RFBClient.handshake(over: ReplayTransport(serverBytes: bytes))
    await #expect {
      try await client.processNextMessage()
    } throws: { Self.isProtocolViolation($0) }
  }
}

func hex(_ s: String) -> [UInt8] {
  stride(from: 0, to: s.count, by: 2).map {
    let i = s.index(s.startIndex, offsetBy: $0)
    return UInt8(s[i..<s.index(i, offsetBy: 2)], radix: 16)!
  }
}

/// Accepts one connection on a unix socket, writes `reply`, then drains until the peer closes.
final class OneShotServer: @unchecked Sendable {
  let fd: Int32
  let path: String

  init(path: String, reply: [UInt8]) throws {
    self.path = path
    unlink(path)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: path.utf8)
      buf[path.utf8.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0, listen(fd, 1) == 0 else { throw RFBError.connectFailed("bind \(path)") }
    let listener = fd
    Thread.detachNewThread {
      let conn = accept(listener, nil, nil)
      guard conn >= 0 else { return }
      var one: Int32 = 1
      setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      var sent = 0
      while sent < reply.count {
        let n = reply.withUnsafeBytes { write(conn, $0.baseAddress! + sent, reply.count - sent) }
        if n <= 0 { break }
        sent += n
      }
      var sink = [UInt8](repeating: 0, count: 4096)
      while sink.withUnsafeMutableBytes({ read(conn, $0.baseAddress!, 4096) }) > 0 {}
      close(conn)
    }
  }

  func stop() {
    close(fd)
    unlink(path)
  }
}
