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
