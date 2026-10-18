import Testing
import VMLabGDB

@Suite struct CommandsTests {
  @Test func packetPayloads() {
    #expect(GDBCommand.qSupported.hasPrefix("qSupported:"))
    #expect(GDBCommand.writeRegisters([0x01, 0xFF]) == "G01ff")
    #expect(GDBCommand.readRegister(32) == "p20")
    #expect(GDBCommand.writeRegister(16, value: [0x00, 0x10]) == "P10=0010")
    #expect(GDBCommand.readMemory(address: 0x4000_0000, length: 256) == "m40000000,100")
    #expect(GDBCommand.writeMemory(address: 0x1000, bytes: [0xDE, 0xAD]) == "M1000,2:dead")
    #expect(GDBCommand.vCont([.continue]) == "vCont;c")
    #expect(GDBCommand.vCont([VContAction(.step, thread: "p1.2"), .continue]) == "vCont;s:p1.2;c")
    #expect(
      GDBCommand.readFeatures(annex: "target.xml", offset: 4091, length: 4091)
        == "qXfer:features:read:target.xml:ffb,ffb")
  }

  @Test(arguments: BreakpointType.allCases)
  func pointPackets(type: BreakpointType) {
    #expect(
      GDBCommand.insertPoint(type, address: 0xFFFF_0000_1000, kind: 4)
        == "Z\(type.rawValue),ffff00001000,4")
    #expect(
      GDBCommand.removePoint(type, address: 0xFFFF_0000_1000, kind: 4)
        == "z\(type.rawValue),ffff00001000,4")
    #expect(type.isWatchpoint == (type.rawValue >= 2))
  }

  @Test func watchpointPacketsCarryTheWatchedLength() {
    #expect(
      GDBCommand.insertPoint(.writeWatchpoint, address: 0x7ffe_0000, kind: 8) == "Z2,7ffe0000,8")
    #expect(
      GDBCommand.insertPoint(.readWatchpoint, address: 0x7ffe_0000, kind: 4) == "Z3,7ffe0000,4")
    #expect(
      GDBCommand.insertPoint(.accessWatchpoint, address: 0x7ffe_0000, kind: 1) == "Z4,7ffe0000,1")
  }

  @Test func parsesQSupported() {
    let features = StubFeatures.parse(
      "PacketSize=1000;qXfer:features:read+;swbreak+;hwbreak-;vContSupported+")
    #expect(features.packetSize == 4096)
    #expect(features.supports("qXfer:features:read"))
    #expect(features.supports("swbreak"))
    #expect(!features.supports("hwbreak"))
  }

  @Test func parsesVContQuery() {
    #expect(parseVContActions("vCont;c;C;s;S") == ["c", "C", "s", "S"])
    #expect(parseVContActions("") == nil)
  }
}
