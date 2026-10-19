import Foundation
import Testing
import VMLabGDB

/// The real socket transport against a one-connection stub on loopback.
@Suite struct TransportTests {
  /// Listens on an ephemeral loopback port and, on one connection, acks each packet and answers
  /// `qSupported` and `g`.
  final class LoopbackStub: @unchecked Sendable {
    let port: UInt16
    private let listener: TestListener

    init() throws {
      let server = socket(AF_INET, SOCK_STREAM, 0)
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      address.sin_port = 0
      var size = socklen_t(MemoryLayout<sockaddr_in>.size)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, size) }
      }
      guard bound == 0, listen(server, 1) == 0 else {
        close(server)
        throw GDBError.connectionFailed("bind")
      }
      _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &size) }
      }
      port = UInt16(bigEndian: address.sin_port)
      let listener = TestListener(server)
      self.listener = listener
      Thread {
        guard let fd = listener.accept() else { return }
        var decoder = GDBPacketDecoder()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
          guard count > 0 else { break }
          // Client frames decode the same way as stub frames.
          for case .packet(let payload) in decoder.feed(buffer[0..<count]) {
            let text = String(decoding: payload, as: UTF8.self)
            let reply =
              text.hasPrefix("qSupported")
              ? "PacketSize=1000" : text == "g" ? GDBFixtures.littleEndian(0x42) : ""
            let out = GDBPacket.ack + GDBPacket.frame(reply)
            _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
          }
        }
        close(fd)
      }.start()
    }

    deinit { listener.close() }
  }

  @Test func talksToAStubOverLoopback() async throws {
    let stub = try LoopbackStub()
    let client = try await GDBClient.connect(
      port: stub.port, options: .init(fallbackArchitecture: .arm64))
    #expect(await client.features?.packetSize == 0x1000)
    #expect(try await client.register(named: "x0").uint64 == 0x42)
    await client.close()
    await #expect(throws: GDBError.self) { try await client.readRegistersRaw() }
  }

  @Test func refusedConnectionIsConnectionFailed() {
    // Port 1 has no listener on a development Mac.
    #expect(throws: GDBError.self) { try GDBTCPTransport(host: "127.0.0.1", port: 1) }
  }
}

@Suite struct GDBTransportPoolTests {
  /// Sends to a stub that never reads block once the socket buffers fill; they wait off the
  /// cooperative pool, so other tasks still run.
  @Test func stalledSendsLeaveThePoolFree() async throws {
    let stub = try PoolSaturation.SilentTCPListener()
    let payload = [UInt8](repeating: 0x2B, count: 16 << 20)
    let latency = await PoolSaturation.latency { _ in
      guard let transport = try? await GDBTCPTransport.open(host: "127.0.0.1", port: stub.port)
      else { return }
      try? await transport.send(payload)
      await transport.close()
    }
    #expect(latency < PoolSaturation.budget)
  }
}
