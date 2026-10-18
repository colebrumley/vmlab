import Testing
import VMLabCore

@Suite struct LoggingTests {
  @Test func levelComesFromVMLABLOG() {
    #expect(VMLabLogging.level(environment: [:]) == .info)
    #expect(VMLabLogging.level(environment: ["VMLAB_LOG": "debug"]) == .debug)
    #expect(VMLabLogging.level(environment: ["VMLAB_LOG": "TRACE"]) == .trace)
    #expect(VMLabLogging.level(environment: ["VMLAB_LOG": "loud"]) == .info)
  }
}
