import Darwin
import Testing

@testable import VMLabRFB

@Suite struct RFBTransportTests {
  /// Codex P3: a TCP connect had no deadline, so an address that drops the SYN (TEST-NET-1 here)
  /// held the caller for the kernel's timeout. It now fails within the one it is given.
  @Test func tcpConnectHasADeadline() async {
    let elapsed = await ContinuousClock().measure {
      await #expect(throws: RFBError.self) {
        _ = try await SocketTransport.connect(
          .tcp(host: "192.0.2.1", port: 5900), timeout: .milliseconds(300))
      }
    }
    #expect(elapsed < .seconds(2))
  }

  /// A listening loopback port still connects through the non-blocking path.
  @Test func tcpConnectToAListenerSucceeds() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    #expect(listener >= 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
    }
    #expect(bound == 0)
    #expect(listen(listener, 4) == 0)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
    }
    let port = UInt16(bigEndian: address.sin_port)
    let transport = try await SocketTransport.connect(.tcp(host: "127.0.0.1", port: port))
    await transport.close()
  }
}

@Suite struct RFBTransportPoolTests {
  /// Connects that wait for an address that never answers hold no thread of the cooperative
  /// pool (nor of `DispatchQueue.global()`, which is as narrow): other tasks still run.
  @Test func pendingConnectsLeaveThePoolFree() async {
    let latency = await PoolSaturation.latency { _ in
      _ = try? await SocketTransport.connect(
        .tcp(host: "192.0.2.1", port: 5900), timeout: PoolSaturation.hold)
    }
    #expect(latency < PoolSaturation.budget)
  }
}
