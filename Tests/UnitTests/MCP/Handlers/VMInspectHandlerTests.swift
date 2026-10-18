import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

@Suite struct VMInspectHandlerTests {
  /// R-308: the chosen forward ports are part of the endpoints vm_create and vm_inspect return.
  @Test func endpointsListTheChosenForwards() {
    let runtime = VMRuntime(
      pid: 1, controlSocket: "/q", sshPort: 52222,
      forwards: [PortForward(guest: 80, host: 8080), PortForward(guest: 443, host: 49152)])
    let endpoints = VMInspectHandler.endpoints(runtime)
    #expect(endpoints["ssh"] == .string("127.0.0.1:52222"))
    #expect(
      endpoints["forwards"]
        == .array([
          .object(["guest": .number(80), "host": .string("127.0.0.1:8080")]),
          .object(["guest": .number(443), "host": .string("127.0.0.1:49152")]),
        ]))
    #expect(VMInspectHandler.endpoints(VMRuntime(pid: 1, controlSocket: "/q"))["forwards"] == nil)
  }
}
