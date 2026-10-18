import Foundation
import Testing
import VMLabGDB

@Suite struct GDBClientTests {
  /// A QEMU-like arm64 stub: serves `target.xml` and its includes in small `qXfer` chunks, and a
  /// `g` reply with x0 = 0x1000, x1..x30 = n * 0x10, sp = 0xffff00008000fff0, pc = 0x40080000.
  static func arm64Stub(chunk: Int = 100) throws -> FakeGDBStub {
    FakeGDBStub(handler: try arm64Handler(chunk: chunk))
  }

  /// The answers of `arm64Stub`, for stubs on other transports.
  static func arm64Handler(chunk: Int = 100) throws -> FakeGDBStub.Handler {
    let annexes = [
      "target.xml": try GDBFixtures.text("target.xml"),
      "aarch64-core.xml": try GDBFixtures.text("aarch64-core.xml"),
      "aarch64-fpu.xml": try GDBFixtures.text("aarch64-fpu.xml"),
    ]
    var g = GDBFixtures.littleEndian(0x1000)
    for index in 1...30 { g += GDBFixtures.littleEndian(UInt64(index) * 0x10) }
    g += GDBFixtures.littleEndian(0xffff_0000_8000_fff0)
    g += GDBFixtures.littleEndian(0x4008_0000)
    g += GDBFixtures.littleEndian(0x3c5, bytes: 4)
    let registers = g
    return { packet in
      if packet.hasPrefix("qSupported") {
        return ["PacketSize=1000;qXfer:features:read+;vContSupported+"]
      }
      if packet == "g" { return [registers] }
      if packet == "?" { return ["T05thread:p01.01;"] }
      if packet == "p20" { return [GDBFixtures.littleEndian(0x4008_0000)] }
      if packet.hasPrefix("qXfer:features:read:") {
        let fields = packet.dropFirst("qXfer:features:read:".count).split(separator: ":")
        guard let text = annexes[String(fields[0])] else { return ["E00"] }
        let range = fields[1].split(separator: ",")
        let offset = Int(range[0], radix: 16) ?? 0
        let length = min(Int(range[1], radix: 16) ?? 0, chunk)
        let bytes = Array(text.utf8)
        let end = min(bytes.count, offset + length)
        let slice = String(decoding: bytes[min(offset, bytes.count)..<end], as: UTF8.self)
        return [(end == bytes.count ? "l" : "m") + slice]
      }
      return [""]
    }
  }

  /// Answers nothing to `c` (the target runs) and empty to everything else.
  static func silentWhileRunning() -> FakeGDBStub {
    FakeGDBStub { packet in packet == "c" ? [] : [""] }
  }

  @Test func namesPcSpAndX0FromTargetXMLAndGReply() async throws {
    let stub = try Self.arm64Stub()
    let client = GDBClient(transport: stub)
    let features = try await client.handshake()
    #expect(features.supports("qXfer:features:read"))
    let map = try await client.registerMap()
    #expect(map.architecture == "aarch64")
    #expect(map.registers.count == 68)
    #expect(try await client.register(named: "pc").uint64 == 0x4008_0000)
    #expect(try await client.register(named: "sp").uint64 == 0xffff_0000_8000_fff0)
    #expect(try await client.register(named: "x0").uint64 == 0x1000)
    let readings = try await client.registers()
    #expect(readings.count == 34)
    #expect(readings.first { $0.register.name == "x30" }?.value?.uint64 == 0x1e0)
    #expect(readings.first { $0.register.name == "cpsr" }?.value?.uint64 == 0x3c5)
    #expect(stub.received.filter { $0.hasPrefix("qXfer:features:read:target.xml") }.count > 1)
    #expect(stub.badFrames == 0)
    await #expect(throws: GDBError.unknownRegister("rip")) {
      try await client.register(named: "rip")
    }
  }

  @Test func haltReasonReadsPcWhenNotExpedited() async throws {
    let stub = try Self.arm64Stub()
    let client = GDBClient(transport: stub)
    _ = try await client.handshake()
    let reason = try await client.haltReason()
    #expect(reason == StopReason(kind: .signal, signal: 5, thread: "p01.01", pc: 0x4008_0000))
    #expect(stub.received.last == "p20")
  }

  @Test func replaysTheX86_64SessionTranscript() async throws {
    let replay = TranscriptReplay(try GDBFixtures.text("session-x86_64.txt"))
    let stub = FakeGDBStub { replay.answer($0) }
    let client = GDBClient(
      transport: stub, options: .init(replyTimeout: .seconds(2), fallbackArchitecture: .x86_64))

    let features = try await client.handshake()
    #expect(features.packetSize == 0x1000)
    #expect(!features.supports("qXfer:features:read"))

    let halted = try await client.haltReason()
    #expect(halted.pc == 0xfff0)
    #expect(try await client.vContActions() == ["c", "C", "s", "S"])

    let raw = try await client.readRegistersRaw()
    let readings = try await client.registerMap().decode(registersReply: raw)
    #expect(readings.first { $0.register.name == "rax" }?.value?.uint64 == 0x1111)
    #expect(readings.first { $0.register.name == "rsp" }?.value?.uint64 == 0x1111 * 8)
    #expect(readings.first { $0.register.name == "rip" }?.value?.uint64 == 0xffff_ffff_8100_0000)
    #expect(readings.first { $0.register.name == "cs" }?.value?.uint64 == 0x10)
    try await client.writeRegisters(Hex.decode(raw)!)
    try await client.setRegister(named: "pc", value: 0x1000)

    let memory = try await client.readMemory(address: 0x1000, length: 16)
    #expect(Array(memory.prefix(13)) == Array("Hello, world!".utf8))
    try await client.writeMemory(address: 0x1000, bytes: [0xDE, 0xAD, 0xBE, 0xEF])
    await #expect(throws: GDBError.stubError(code: 0x14, message: nil)) {
      try await client.readMemory(address: 0x2000, length: 4)
    }

    try await client.insertBreakpoint(.software, address: 0xffff_ffff_8100_0000, kind: 1)
    try await client.removeBreakpoint(.software, address: 0xffff_ffff_8100_0000, kind: 1)
    try await client.insertBreakpoint(.hardware, address: 0x40_1000, kind: 1)
    try await client.removeBreakpoint(.hardware, address: 0x40_1000, kind: 1)
    try await client.insertBreakpoint(.writeWatchpoint, address: 0x7ffe_0000, kind: 8)
    try await client.insertBreakpoint(.readWatchpoint, address: 0x7ffe_0000, kind: 4)
    try await client.insertBreakpoint(.accessWatchpoint, address: 0x7ffe_0000, kind: 1)
    try await client.removeBreakpoint(.writeWatchpoint, address: 0x7ffe_0000, kind: 8)
    try await client.removeBreakpoint(.readWatchpoint, address: 0x7ffe_0000, kind: 4)
    try await client.removeBreakpoint(.accessWatchpoint, address: 0x7ffe_0000, kind: 1)

    try await client.cont()
    #expect(await client.state == .running)
    await #expect(throws: GDBError.targetRunning) { try await client.readRegistersRaw() }
    let interrupted = try await client.halt(timeout: .seconds(2))
    #expect(interrupted.signal == 2)
    #expect(interrupted.pc == 0x1234)
    #expect(await client.state == .stopped)

    try await client.step()
    let stepped = try await client.waitForStop(timeout: .seconds(2))
    #expect(stepped.pc == 0x1236)
    #expect(stepped.breakpoint == .software)

    try await client.vCont([.continue])
    let watched = try await client.waitForStop(timeout: .seconds(2))
    #expect(watched.watchpoint == .init(kind: .write, address: 0x7ffe_0000))
    #expect(watched.pc == 0x1240)
    #expect(await client.consoleOutput == Array("Hi\n".utf8))

    try await client.vCont([VContAction(.step, thread: "p1.1")])
    let single = try await client.waitForStop(timeout: .seconds(2))
    #expect(single.pc == 0x1244)

    try await client.vCont([.continue])
    let exited = try await client.waitForStop(timeout: .seconds(2))
    #expect(exited.kind == .exited(status: 0))

    #expect(replay.failures.isEmpty, "\(replay.failures)")
    #expect(replay.finished)
    #expect(stub.badFrames == 0)
  }

  @Test func resendsAfterNack() async throws {
    let stub = FakeGDBStub(nackFirst: 2) { _ in ["OK"] }
    let client = GDBClient(transport: stub)
    try await client.insertBreakpoint(.software, address: 0x1000, kind: 4)
    #expect(stub.received == ["Z0,1000,4"])
  }

  /// A write that finds the connection gone closes the client, even before the reader has seen
  /// end of file (the stub's half of a TCP hang-up can arrive in either order).
  @Test func aFailedWriteClosesTheClient() async throws {
    final class Unwritable: GDBTransport, @unchecked Sendable {
      let incoming = AsyncThrowingStream<[UInt8], any Error> { _ in }
      func send(_ bytes: [UInt8]) async throws { throw GDBError.connectionClosed }
      func close() async {}
    }
    let client = GDBClient(transport: Unwritable())
    #expect(!(await client.isClosed))
    await #expect(throws: GDBError.connectionClosed) {
      try await client.insertBreakpoint(.software, address: 0x1000, kind: 4)
    }
    #expect(await client.isClosed)
  }

  @Test func givesUpAfterTooManyNacks() async throws {
    let stub = FakeGDBStub(nackFirst: 10) { _ in ["OK"] }
    let client = GDBClient(transport: stub, options: .init(maxRetransmits: 3))
    await #expect(throws: GDBError.tooManyRetransmits) {
      try await client.insertBreakpoint(.software, address: 0x1000, kind: 4)
    }
  }

  @Test func asksForResendOfCorruptReplyAndAcksGoodOnes() async throws {
    let stub = Self.silentWhileRunning()
    let client = GDBClient(transport: stub)
    try await client.cont()
    stub.inject(Array("$S05#00".utf8))  // bad checksum
    stub.push("S05")
    let stop = try await client.waitForStop(timeout: .seconds(2))
    #expect(stop.signal == 5)
    #expect(stub.nacksFromClient == 1)
    #expect(stub.acksFromClient >= 1)
  }

  @Test func decodesRunLengthEncodedReplies() async throws {
    // "000*\"" is "000" and five more ('"' is 34, 34 - 29 = 5): eight zero digits.
    let stub = FakeGDBStub { packet in packet == "m0,4" ? ["000*\""] : [""] }
    let client = GDBClient(transport: stub)
    #expect(try await client.readMemory(address: 0, length: 4) == [0, 0, 0, 0])
  }

  @Test func mapsEmptyAndErrorReplies() async throws {
    let stub = FakeGDBStub { packet in
      switch packet {
      case "p99": [""]
      case "p98": ["E.no such register"]
      case "vCont?": [""]
      default: ["E01"]
      }
    }
    let client = GDBClient(transport: stub)
    await #expect(throws: GDBError.unsupported(packet: "p99")) {
      try await client.readRegister(number: 0x99)
    }
    await #expect(throws: GDBError.stubError(code: -1, message: "no such register")) {
      try await client.readRegister(number: 0x98)
    }
    #expect(try await client.vContActions() == nil)
    await #expect(throws: GDBError.stubError(code: 1, message: nil)) {
      try await client.writeMemory(address: 0, bytes: [1])
    }
  }

  @Test func noTargetDescriptionWithoutFallback() async throws {
    let stub = FakeGDBStub { _ in [""] }
    let client = GDBClient(transport: stub)
    await #expect(throws: GDBError.noTargetDescription) { try await client.registerMap() }
    let fallback = GDBClient(
      transport: FakeGDBStub { _ in [""] }, options: .init(fallbackArchitecture: .arm64))
    #expect(try await fallback.registerMap() == RegisterMap.builtin(.arm64))
  }

  @Test func splitsLargeMemoryAccessesByPacketSize() async throws {
    let stub = FakeGDBStub { packet in
      if packet.hasPrefix("qSupported") { return ["PacketSize=100"] }
      if packet.hasPrefix("m") {
        let length = Int(packet.split(separator: ",")[1], radix: 16)!
        return [String(repeating: "ab", count: length)]
      }
      if packet.hasPrefix("M") { return ["OK"] }
      return [""]
    }
    let client = GDBClient(transport: stub)
    _ = try await client.handshake()
    let bytes = try await client.readMemory(address: 0x1000, length: 300)
    #expect(bytes == [UInt8](repeating: 0xAB, count: 300))
    try await client.writeMemory(address: 0x1000, bytes: [UInt8](repeating: 1, count: 300))
    let reads = stub.received.filter { $0.hasPrefix("m") }
    let writes = stub.received.filter { $0.hasPrefix("M") }
    #expect(reads.count == 3)  // (256 - 8) / 2 = 124 bytes per packet
    #expect(reads[1] == "m107c,7c")
    #expect(writes.count == 3)  // (256 - 40) / 2 = 108 bytes per packet
    #expect(writes.allSatisfy { $0.count <= 256 })
  }

  @Test func waitForStopTimesOutAndKeepsTheLateStop() async throws {
    let stub = Self.silentWhileRunning()
    let client = GDBClient(transport: stub)
    try await client.cont()
    await #expect(throws: GDBError.timeout(seconds: 0.05)) {
      try await client.waitForStop(timeout: .milliseconds(50))
    }
    #expect(await client.state == .running)
    stub.push("T05")
    #expect(try await client.waitForStop(timeout: .seconds(2)).signal == 5)
    // Already stopped: returns the last stop at once.
    #expect(try await client.waitForStop(timeout: .milliseconds(1)).signal == 5)
  }

  @Test func waitForStopBeforeAnyStopAsksHaltReason() async throws {
    let stub = FakeGDBStub { packet in packet == "?" ? ["S05"] : [""] }
    let client = GDBClient(transport: stub)
    #expect(try await client.waitForStop(timeout: .seconds(2)).signal == 5)
    #expect(stub.received.first == "?")
  }

  @Test func connectionClosedFailsWaiters() async throws {
    let stub = Self.silentWhileRunning()
    let client = GDBClient(transport: stub)
    try await client.cont()
    stub.hangUp()
    await #expect(throws: GDBError.connectionClosed) {
      try await client.waitForStop(timeout: .seconds(2))
    }
    await #expect(throws: GDBError.connectionClosed) { try await client.interrupt() }
  }

  @Test func concurrentCommandsAreSerialised() async throws {
    let stub = FakeGDBStub { packet in
      guard let number = Int(packet.dropFirst(), radix: 16) else { return [""] }
      return [GDBFixtures.littleEndian(UInt64(number))]
    }
    let client = GDBClient(transport: stub)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for number in 0..<20 {
        group.addTask {
          let bytes = try await client.readRegister(number: number)
          #expect(Hex.littleEndian(bytes) == UInt64(number))
        }
      }
      try await group.waitForAll()
    }
    #expect(stub.received.count == 20)
  }
}
