import Testing
import VMLabGDB

@Suite struct PacketTests {
  @Test func framesWithChecksum() {
    #expect(String(decoding: GDBPacket.frame("g"), as: UTF8.self) == "$g#67")
    #expect(String(decoding: GDBPacket.frame("?"), as: UTF8.self) == "$?#3f")
    #expect(String(decoding: GDBPacket.frame(""), as: UTF8.self) == "$#00")
  }

  @Test func escapesReservedBytesAndChecksumsTheEscapedForm() {
    let payload: [UInt8] = [0x23, 0x41, 0x24, 0x7D, 0x2A]
    let escaped: [UInt8] = [0x7D, 0x03, 0x41, 0x7D, 0x04, 0x7D, 0x5D, 0x7D, 0x0A]
    #expect(GDBPacket.escape(payload) == escaped)
    #expect(GDBPacket.unescape(escaped) == payload)
    let sum = Hex.byte(GDBPacket.checksum(escaped))
    let framed: [UInt8] = [0x24] + escaped + [0x23] + Array(sum.utf8)
    #expect(GDBPacket.frame(payload) == framed)
  }

  @Test func expandsRunLengthEncoding() {
    // "0* " is "0" and three more (space is 32, 32 - 29 = 3).
    #expect(GDBPacket.expandRunLength(Array("0* ".utf8)) == Array("0000".utf8))
    #expect(GDBPacket.expandRunLength(Array("ab*\"c".utf8)) == Array("abbbbbbc".utf8))
    #expect(GDBPacket.expandRunLength(Array("OK".utf8)) == Array("OK".utf8))
  }

  @Test func decodesAcksPacketsAndSplitChunks() {
    var decoder = GDBPacketDecoder()
    #expect(decoder.feed(Array("+$O".utf8)) == [.ack])
    #expect(decoder.feed(Array("K#9".utf8)) == [])
    #expect(decoder.feed(Array("a-".utf8)) == [.packet(Array("OK".utf8)), .nack])
  }

  @Test func decodesRunLengthReplies() {
    var decoder = GDBPacketDecoder()
    let body = Array("0* ".utf8)
    let frame = Array("$".utf8) + body + Array("#\(Hex.byte(GDBPacket.checksum(body)))".utf8)
    #expect(decoder.feed(frame) == [.packet(Array("0000".utf8))])
  }

  @Test func flagsBadChecksumAndIgnoresNoiseAndNotifications() {
    var decoder = GDBPacketDecoder()
    #expect(decoder.feed(Array("$OK#00".utf8)) == [.corrupt])
    #expect(decoder.feed(Array("xyz%Stop:T05#00$OK#9a".utf8)) == [.packet(Array("OK".utf8))])
  }

  @Test func hexHelpers() {
    #expect(Hex.encode([0xDE, 0xAD, 0x01]) == "dead01")
    #expect(Hex.decode("DEad01") == [0xDE, 0xAD, 0x01])
    #expect(Hex.decode("abc") == nil)
    #expect(Hex.decode("zz") == nil)
    #expect(Hex.littleEndian([0x34, 0x12]) == 0x1234)
    #expect(Hex.littleEndian([]) == nil)
    #expect(Hex.number(UInt64(0xffff_ffff_8100_0000)) == "ffffffff81000000")
  }
}
