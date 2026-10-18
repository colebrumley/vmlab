import Testing
import VMLabGDB

@Suite struct TargetDescriptionTests {
  static func qemuArm64Map() throws -> RegisterMap {
    try RegisterMap.build(
      targetXML: GDBFixtures.text("target.xml"),
      annexes: [
        "aarch64-core.xml": GDBFixtures.text("aarch64-core.xml"),
        "aarch64-fpu.xml": GDBFixtures.text("aarch64-fpu.xml"),
      ])
  }

  @Test func listsIncludesInOrder() throws {
    #expect(
      try RegisterMap.includes(in: GDBFixtures.text("target.xml")) == [
        "aarch64-core.xml", "aarch64-fpu.xml",
      ])
  }

  @Test func buildsArm64MapFromIncludes() throws {
    let map = try Self.qemuArm64Map()
    #expect(map.architecture == "aarch64")
    #expect(map.registers.count == 34 + 34)
    #expect(map.register(named: "x0")?.number == 0)
    #expect(map.register(named: "sp")?.number == 31)
    #expect(map.programCounter?.number == 32)
    #expect(map.register(named: "cpsr")?.bitSize == 32)
    // regnum="34" on v0, then numbering continues from there.
    #expect(map.register(named: "v0")?.number == 34)
    #expect(map.register(named: "v31")?.number == 65)
    #expect(map.register(named: "fpcr")?.number == 67)
    #expect(map.register(named: "PC") == map.programCounter)
    #expect(map.register(number: 32)?.name == "pc")
    #expect(map.register(named: "rip") == nil)
  }

  @Test func missingIncludeIsAnError() throws {
    #expect(throws: GDBError.badTargetDescription("missing included annex aarch64-core.xml")) {
      try RegisterMap.build(targetXML: GDBFixtures.text("target.xml"))
    }
  }

  @Test func malformedXMLIsAnError() {
    #expect(throws: GDBError.self) { try RegisterMap.build(targetXML: "<target><reg name=") }
    #expect(throws: GDBError.self) {
      try RegisterMap.build(targetXML: "<target><reg name=\"x\"/></target>")
    }
  }

  @Test func builtinArm64MatchesQEMUCoreLayout() {
    let map = RegisterMap.builtin(.arm64)
    #expect(map.architecture == "aarch64")
    #expect(map.registers.count == 34)
    #expect(map.register(named: "x30")?.number == 30)
    #expect(map.register(named: "sp")?.number == 31)
    #expect(map.programCounter?.number == 32)
    #expect(map.register(named: "cpsr")?.number == 33)
    #expect(GDBArchitecture(targetArchitecture: "aarch64") == .arm64)
    #expect(GDBArchitecture.arm64.breakpointKind == 4)
  }

  @Test func builtinX86_64AliasesPcAndSp() {
    let map = RegisterMap.builtin(.x86_64)
    #expect(map.architecture == "i386:x86-64")
    #expect(map.programCounter?.name == "rip")
    #expect(map.programCounter?.number == 16)
    #expect(map.register(named: "sp")?.name == "rsp")
    #expect(map.register(named: "eflags")?.bitSize == 32)
    #expect(map.register(named: "efer")?.number == 32)
    #expect(GDBArchitecture(targetArchitecture: "i386:x86-64") == .x86_64)
    #expect(GDBArchitecture.x86_64.breakpointKind == 1)
  }

  @Test func decodesAPrefixGReplyWithUnavailableRegisters() throws {
    let map = RegisterMap.builtin(.arm64)
    var reply = ""
    for index in 0..<31 { reply += GDBFixtures.littleEndian(UInt64(index) * 0x100) }
    reply += GDBFixtures.littleEndian(0xffff_0000_8000_0000)  // sp
    reply += "xxxxxxxxxxxxxxxx"  // pc unavailable
    let readings = try map.decode(registersReply: reply)
    #expect(readings.count == 33)  // cpsr not sent
    #expect(readings[1].value?.uint64 == 0x100)
    #expect(readings[31].register.name == "sp")
    #expect(readings[31].value?.hex == "0xffff000080000000")
    #expect(readings[32].register.name == "pc")
    #expect(readings[32].value == nil)
    #expect(throws: GDBError.self) { try map.decode(registersReply: "abc") }
    #expect(throws: GDBError.self) { try map.decode(registersReply: "zz00000000000000") }
  }
}
