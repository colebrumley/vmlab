import Foundation
import Testing
import VMLabCore
import VMLabQEMU

/// `UnixQMPTransport` against a peer that accepts and never reads: a hung QEMU (CX-13).
@Suite struct QMPTransportTests {
  @Test func aSendToAPeerThatStopsReadingTimesOut() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let transport = try await UnixQMPTransport.connect(
      path: server.path, writeStall: .milliseconds(300))
    await server.accept()
    do {
      try await transport.send(Data(repeating: 0x20, count: 8 << 20))
      Issue.record("expected timeout")
    } catch let error as VMLabError {
      #expect(error.code == .timeout)
    }
    await transport.close()
  }

  @Test(.timeLimit(.minutes(1))) func closeProceedsDuringAStuckSend() async throws {
    let server = try FakeSerialServer()
    defer { server.cleanUp() }
    let transport = try await UnixQMPTransport.connect(path: server.path, writeStall: .seconds(120))
    await server.accept()
    let send = Task { try await transport.send(Data(repeating: 0x20, count: 8 << 20)) }
    try await Task.sleep(for: .milliseconds(200))
    await transport.close()
    do {
      try await send.value
      Issue.record("expected guest_unreachable")
    } catch let error as VMLabError {
      #expect(error.code == .guestUnreachable)
    }
  }
}
