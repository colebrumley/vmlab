import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

/// R-309: net_fast picks `-netdev vmnet-shared` exactly when the request asked for it and the
/// host can (root or `qemu_vmnet` = yes); everywhere else the plan refuses it.
@Suite struct QEMUVmnetProbeTests {
  static func host(vmnet: ProbeResult, root: Bool = false) -> HostFacts {
    var host = CapabilitiesTests.host(probes: .unknown)
    host.probes[.qemuVmnet] = ProbeRecord(result: vmnet)
    host.isRoot = root
    return host
  }

  static func record(for plan: Plan, network: NetworkSpec = NetworkSpec(mode: .nat)) -> VMRecord {
    VMRecord(
      id: "vm-net234", profile: plan.profile, guest: plan.guest, features: plan.features,
      resources: plan.resources, image: "debian-13-arm64", network: network, plan: plan)
  }

  static func arguments(_ record: VMRecord, vmnet: Bool) throws -> [String] {
    try QEMUCommandLine.arguments(
      record: record, plan: record.plan!,
      layout: QEMULayout(vmDirectory: URL(filePath: "/Users/someone/.vmlab/vms/\(record.id)")),
      options: QEMULaunchOptions(
        firmware: QEMUCommandLineTests.firmware, gdbPort: 1234, sshHostPort: vmnet ? nil : 52222,
        vmnet: vmnet))
  }

  @Test func netFastUsesVmnetWhenTheHostCan() throws {
    let request = try Requirements(
      guest: GuestSpec(os: .linux, arch: .arm64), require: [.netFast, .introspection])
    for host in [Self.host(vmnet: .yes), Self.host(vmnet: .no, root: true)] {
      let plan = try ProfileSelector.select(request, host: host, running: .empty).get()
      #expect(plan.profile == .qemuHVF)
      let record = Self.record(for: plan)
      #expect(QEMUBackend.usesVmnet(record))
      let args = try Self.arguments(record, vmnet: true)
      let text = args.joined(separator: "\n") + "\n"
      let snapshot = QEMUCommandLineTests.fixtures.appending(path: "net-vmnet.args")
      if ProcessInfo.processInfo.environment["VMLAB_UPDATE_SNAPSHOTS"] == "1" {
        try Data(text.utf8).write(to: snapshot)
      }
      #expect(text == (try String(contentsOf: snapshot, encoding: .utf8)))
      #expect(args.contains("vmnet-shared,id=net0") && !args.contains { $0.contains("hostfwd") })
    }
    // Without root or the probe no QEMU profile has net_fast.
    let refused = ProfileSelector.select(request, host: Self.host(vmnet: .no), running: .empty)
    #expect(throws: Unsatisfiable.self) { try refused.get() }
    let vz = try ProfileSelector.select(
      try Requirements(guest: GuestSpec(os: .linux, arch: .arm64), require: [.netFast]),
      host: Self.host(vmnet: .no), running: .empty
    ).get()
    #expect(vz.profile == .vzLinux)
  }

  @Test func netFastTheProfileMerelyHasKeepsUserNetworking() throws {
    let request = try Requirements(
      guest: GuestSpec(os: .linux, arch: .arm64), require: [.introspection])
    let plan = try ProfileSelector.select(request, host: Self.host(vmnet: .yes), running: .empty)
      .get()
    #expect(plan.grants(.netFast) && !plan.requests(.netFast))
    let record = Self.record(for: plan)
    #expect(!QEMUBackend.usesVmnet(record))
    var offline = record
    offline.network = NetworkSpec(mode: .disabled)
    offline.plan?.requested.append(.netFast)
    #expect(!QEMUBackend.usesVmnet(offline))
  }

  @Test func vmnetRefusesPortForwards() throws {
    let request = try Requirements(
      guest: GuestSpec(os: .linux, arch: .arm64), require: [.netFast, .introspection])
    let plan = try ProfileSelector.select(request, host: Self.host(vmnet: .yes), running: .empty)
      .get()
    let record = Self.record(
      for: plan, network: NetworkSpec(mode: .nat, forwards: [PortForward(guest: 80, host: 8080)]))
    #expect {
      try Self.arguments(record, vmnet: true)
    } throws: { ($0 as? VMLabError)?.data["field"] == .string("network.forwards") }
  }

  @Test func refusalIsRecognisedFromQEMUsMessage() {
    let refused = VMLabError(
      code: .engineError, message: "QEMU exited with status 1 while starting.", hint: "",
      data: [
        "raw": .string(
          "qemu-system-aarch64: -netdev vmnet-shared,id=net0: cannot create vmnet interface: "
            + "general failure (possibly not enough privileges)")
      ])
    #expect(QEMUVmnetProbe.isVmnetRefusal(refused))
    let other = VMLabError(
      code: .engineError, message: "", hint: "", data: ["raw": .string("Could not open disk")])
    #expect(!QEMUVmnetProbe.isVmnetRefusal(other))
    #expect(
      QEMUVmnetProbe.request(
        layout: QEMULayout(vmDirectory: URL(filePath: "/tmp/p")), base: URL(filePath: "/tmp/b"),
        installation: QEMUInstallation(
          binDirectory: URL(filePath: "/b"), shareDirectory: URL(filePath: "/s"))
      ).vmnet)
  }
}
