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
          .object([
            "guest": .number(80), "host": .string("127.0.0.1:8080"),
            "hostReachable": .string("127.0.0.1:8080"),
          ]),
          .object([
            "guest": .number(443), "host": .string("127.0.0.1:49152"),
            "hostReachable": .string("127.0.0.1:49152"),
          ]),
        ]))
    #expect(Self.endpoints(VMRuntime(pid: 1, controlSocket: "/q"))["forwards"] == nil)
  }

  /// R-905: a VZ guest's requested forwards are its NAT address, not a mapped port, and
  /// vm_create says which it gave.
  @Test func vzForwardsAreHostReachable() {
    let record = VMRecord(
      id: "vm-aaaaaa", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [.netPortForward],
      network: NetworkSpec(forwards: [PortForward(guest: 8000), PortForward(guest: 22, host: 2222)]
      ),
      state: .running, runtime: VMRuntime(pid: 1, controlSocket: "/c", ip: "192.168.64.7"))
    #expect(
      VMInspectHandler.endpoints(record, store: Self.store)["forwards"]
        == .array([
          .object([
            "guest": .number(8000), "host": .null, "hostReachable": .string("192.168.64.7:8000"),
          ]),
          .object([
            "guest": .number(22), "host": .null, "hostReachable": .string("192.168.64.7:22"),
          ]),
        ]))
    #expect(VMCreateHandler.forwarding(record)["mode"] == .string("host_reachable"))
    #expect(VMCreateHandler.forwardingNote(record)?.hasPrefix("forwards_not_mapped") == true)
    var qemu = record
    qemu.profile = .qemuHVF
    #expect(VMCreateHandler.forwarding(qemu)["mode"] == .string("hostfwd"))
    #expect(VMCreateHandler.forwardingNote(qemu) == nil)
  }

  /// R-1004: a failed first-boot step is a provision_failed warning with the report; a requested
  /// provisioning never collected because SSH never answered says so.
  @Test func provisionFailuresAreWarnings() async throws {
    let context = try ToolHandlerTests.context()
    defer { try? FileManager.default.removeItem(at: context.home) }
    let record = try context.store.create(
      VMRecord(
        id: "", name: "p", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [.execSSH], provision: ProvisionSpec(runCommands: ["exit 3"])))
    let dir = context.store.directory(of: record.id)
    func inspect() async throws -> ToolResult {
      try await ToolHandlers.call(
        "vm_inspect", arguments: .object(["vm": .string(record.id)]), context: context)
    }
    #expect(try await inspect().warnings.isEmpty)

    try await EventLog(vmDirectory: dir).append(
      .lifecycle, "ssh_unreachable: no answer", level: .warning)
    let unknown = try await inspect()
    #expect(unknown.warnings.contains { $0.hasPrefix("provision_unknown: \(record.id)") })
    #expect(unknown.value["provision"] == .null)

    try ProvisionReport(
      vm: record.id,
      steps: [
        ProvisionStep(
          name: "cloud-init", command: "cloud-init status --wait", status: .failed, exitCode: 1),
        ProvisionStep(
          name: "runCommands[0]", command: "exit 3", status: .failed, exitCode: 3, durationMs: 4),
      ]
    ).write(to: dir)
    let failed = try await inspect()
    #expect(failed.warnings.count == 1)
    #expect(
      failed.warnings[0].hasPrefix(
        "provision_failed: \(record.id) step runCommands[0] `exit 3` exited 3"))
    #expect(failed.value["provision"]?["steps"]?.arrayValue?.count == 2)
  }

  /// R-1202: a bare machine shows `image: "none"` in vm_inspect and vm_list, with no SSH endpoint
  /// and no provisioning; an image's VM shows its image.
  @Test func aBareMachineShowsImageNone() async throws {
    let f = try VMCreateHandlerTests.Fixture()
    defer { f.cleanUp() }
    _ = try await f.create(["requirements": try VMCreateHandlerTests.bare("kernel")])
    let inspect = try await ToolHandlers.call(
      "vm_inspect", arguments: .object(["vm": .string("web")]), context: f.context)
    #expect(inspect.value["image"] == .string("none"))
    #expect(inspect.value["record"]?["image"] == nil)
    #expect(inspect.value["endpoints"]?["ssh"] == nil)
    #expect(inspect.value["provision"] == .null)
    #expect(!inspect.warnings.contains { $0.hasPrefix("provision_") })
    _ = try await f.create(["name": .string("db"), "autostart": .bool(false)])
    let list = try await ToolHandlers.call("vm_list", arguments: .object([:]), context: f.context)
    let images = Dictionary(
      uniqueKeysWithValues: (list.value["vms"]?.arrayValue ?? []).map {
        ($0["name"]?.stringValue ?? "", $0["image"])
      })
    #expect(images["web"] == .string("none"))
    #expect(images["db"] == .string("tiny-arm64"))
  }
}
