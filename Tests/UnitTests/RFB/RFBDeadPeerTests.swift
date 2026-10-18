import Foundation
import Testing
import VMLabCore

@testable import VMLabRFB

/// An RFB server on a still screen: it finishes the handshake, never answers incremental update
/// requests (nothing changed), answers a non-incremental request with an empty update, and once
/// muted answers nothing at all while keeping the connection open (a hung QEMU, R-1101).
actor StillScreenTransport: RFBTransport {
  private var buffer: [UInt8]
  private var reader: (count: Int, continuation: CheckedContinuation<[UInt8], any Error>)?
  private var muted = false
  private var silentHandshake: Bool
  private(set) var forcedRequests = 0
  private(set) var closed = false

  init(silentHandshake: Bool = false) {
    self.silentHandshake = silentHandshake
    var serverInit: [UInt8] = Array("RFB 003.008\n".utf8) + [1, 1] + [0, 0, 0, 0]
    serverInit += [0, 4, 0, 3]  // 4x3
    serverInit += [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
    serverInit += [0, 0, 0, 4] + Array("test".utf8)
    buffer = silentHandshake ? [] : serverInit
  }

  func mute() { muted = true }

  func read(exactly count: Int) async throws -> [UInt8] {
    if closed { throw RFBError.connectionClosed }
    if buffer.count >= count {
      defer { buffer.removeFirst(count) }
      return Array(buffer.prefix(count))
    }
    return try await withCheckedThrowingContinuation { reader = (count, $0) }
  }

  private func feed(_ bytes: [UInt8]) {
    buffer += bytes
    if let pending = reader, buffer.count >= pending.count {
      reader = nil
      let out = Array(buffer.prefix(pending.count))
      buffer.removeFirst(pending.count)
      pending.continuation.resume(returning: out)
    }
  }

  func write(_ bytes: [UInt8]) async throws {
    if closed { throw RFBError.connectionClosed }
    // FramebufferUpdateRequest: type 3, incremental flag, then x, y, w, h.
    guard bytes.first == 3, bytes.count == 10, !muted else { return }
    if bytes[1] == 0 {
      forcedRequests += 1
      feed([0, 0, 0, 0])  // an update with no rectangles
    }
  }

  func close() async {
    closed = true
    if let pending = reader {
      reader = nil
      pending.continuation.resume(throwing: RFBError.connectionClosed)
    }
  }
}

@Suite struct RFBDeadPeerTests {
  @Test func stillScreenIsProbedAndStaysAlive() async throws {
    let transport = StillScreenTransport()
    let client = try await RFBClient.handshake(over: transport, timeout: .seconds(2))
    await client.start(deadPeerWindow: .seconds(3), probeInterval: .milliseconds(40))
    // Polled, so a busy machine only makes it slower.
    let deadline = ContinuousClock.now + .seconds(10)
    while await transport.forcedRequests < 4, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await client.loopError == nil)
    #expect(await transport.forcedRequests >= 4)
    await client.close()
  }

  @Test func silentServerIsDeadWithinTheWindow() async throws {
    let transport = StillScreenTransport()
    let client = try await RFBClient.handshake(over: transport, timeout: .seconds(2))
    await client.start(deadPeerWindow: .milliseconds(300), probeInterval: .milliseconds(40))
    try await client.waitForUpdateCount(1, timeout: .seconds(2))
    await transport.mute()
    let started = ContinuousClock.now
    // An update answered just before the mute may still land; then the silence counts.
    while await client.loopError == nil, ContinuousClock.now - started < .seconds(30) {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard case .deadPeer(let reason)? = await client.loopError else {
      Issue.record("expected deadPeer, got \(String(describing: await client.loopError))")
      return
    }
    #expect(reason.contains("framebuffer update"))
    await #expect(throws: RFBError.self) { try await client.waitForUpdate(timeout: .seconds(1)) }
    #expect(await transport.closed)
  }

  @Test func handshakeThatNeverComesIsDeadPeer() async throws {
    let transport = StillScreenTransport(silentHandshake: true)
    await #expect {
      _ = try await RFBClient.handshake(over: transport, timeout: .milliseconds(200))
    } throws: { error in
      if case .deadPeer = error as? RFBError { return true }
      return false
    }
  }
}
