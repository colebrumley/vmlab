import Testing
import VMLabGDB

@Suite struct StopReasonTests {
  @Test func parsesSignalOnly() throws {
    let reply = try StopReply.parse("S05")
    #expect(reply == StopReply(kind: .signal, signal: 5))
  }

  @Test func parsesTReplyWithThreadRegistersAndInfo() throws {
    let reply = try StopReply.parse("T05thread:p01.01;20:0010000000000000;swbreak:;core:0;")
    #expect(reply.signal == 5)
    #expect(reply.thread == "p01.01")
    #expect(reply.registers == [0x20: [0x00, 0x10, 0, 0, 0, 0, 0, 0]])
    #expect(reply.info == ["swbreak": "", "core": "0"])
    let reason = StopReason(reply: reply, pcRegister: 0x20)
    #expect(reason.pc == 0x1000)
    #expect(reason.breakpoint == .software)
    #expect(reason.thread == "p01.01")
  }

  @Test func parsesExitAndTermination() throws {
    #expect(try StopReply.parse("W00").kind == .exited(status: 0))
    #expect(try StopReply.parse("W01").kind == .exited(status: 1))
    let terminated = try StopReply.parse("X09")
    #expect(terminated.kind == .terminated)
    #expect(terminated.signal == 9)
  }

  @Test(arguments: [
    ("watch", StopReason.WatchpointHit.Kind.write),
    ("rwatch", .read),
    ("awatch", .access),
  ])
  func parsesWatchpointHits(key: String, kind: StopReason.WatchpointHit.Kind) throws {
    let reason = StopReason(
      reply: try StopReply.parse("T05\(key):7ffe0010;thread:1;"), pcRegister: nil)
    #expect(reason.watchpoint == StopReason.WatchpointHit(kind: kind, address: 0x7ffe_0010))
    #expect(reason.pc == nil)
  }

  @Test func hardwareBreakpoint() throws {
    let reason = StopReason(reply: try StopReply.parse("T05hwbreak:;"), pcRegister: 32)
    #expect(reason.breakpoint == .hardware)
  }

  @Test(arguments: ["OK", "", "T", "Tzz", "E01", "O4869"])
  func rejectsNonStopReplies(payload: String) {
    #expect(!StopReply.isStopReply(payload))
    #expect(throws: GDBError.self) { try StopReply.parse(payload) }
  }
}
