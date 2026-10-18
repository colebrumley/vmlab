import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

@Suite struct VMInspectHandlerTests {
  /// R-308: the chosen forward ports are part of the endpoints vm_create and vm_inspect return.
  static let store = Store(home: URL(filePath: "/tmp/vmlab-inspect-unused"))

  static func endpoints(_ runtime: VMRuntime) -> [String: JSONValue] {
    let record = VMRecord(
      id: "vm-aaaaaa", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [], state: .running, runtime: runtime)
    return VMInspectHandler.endpoints(record, store: store)
  }

  @Test func endpointsListTheChosenForwards() {
    let runtime = VMRuntime(
      pid: 1, controlSocket: "/q", sshPort: 52222,
      forwards: [PortForward(guest: 80, host: 8080), PortForward(guest: 443, host: 49152)])
    let endpoints = Self.endpoints(runtime)
    #expect(endpoints["ssh"] == .string("127.0.0.1:52222"))
    #expect(
      endpoints["forwards"]
        == .array([
          .object(["guest": .number(80), "host": .string("127.0.0.1:8080")]),
          .object(["guest": .number(443), "host": .string("127.0.0.1:49152")]),
        ]))
    #expect(Self.endpoints(VMRuntime(pid: 1, controlSocket: "/q"))["forwards"] == nil)
  }
}
