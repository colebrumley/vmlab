import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite(.serialized) struct SegmentIntegrationTests {
  /// The segment NIC's interface and the NAT address of a guest.
  static func interfaces(_ lab: LabHome, _ vm: String, peer: String) async throws -> (
    route: String, nat: String
  ) {
    let route = try await lab.exec(vm, "ip -o route get \(peer)").stdout
    let nat = try await lab.exec(
      vm, "ip -o -4 addr show scope global | grep -v ' 10\\.[1-9][0-9]*\\.0\\.' | awk '{print $4}'"
    ).stdout
    return (route, nat.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// R-901 Verify (integration): two QEMU guests ping each other over the segment, not over NAT
  /// (the segment route is the second NIC, on a subnet the NAT address is not in). R-902: by name.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func twoQEMUGuestsPingOverTheSegment() async throws {
    let lab = try LabHome(tag: "s")
    do {
      let network = NetworkSpec(mode: .nat, segment: "cluster")
      let plan = LabHome.plan(features: [.serial, .execSSH, .netNAT, .netSegment])
      async let first = lab.boot(name: "node-1", plan: plan, network: network)
      async let second = lab.boot(name: "node-2", plan: plan, network: network)
      let (one, two) = try await (first, second)
      #expect(one.warnings.isEmpty && two.warnings.isEmpty, "\(one.warnings) \(two.warnings)")
      let a = try #require(one.record?.segment)
      let b = try #require(two.record?.segment)
      #expect(Set([a.address, b.address]) == ["10.1.0.10", "10.1.0.11"])

      let ping = try await lab.exec("node-1", "ping -c 3 -W 2 \(b.address)")
      #expect(ping.exitCode == 0, "\(ping.stdout)\(ping.stderr)")
      let back = try await lab.exec("node-2", "ping -c 3 -W 2 \(a.address)")
      #expect(back.exitCode == 0, "\(back.stdout)\(back.stderr)")

      let (route, nat) = try await Self.interfaces(lab, "node-1", peer: b.address)
      #expect(!nat.hasPrefix("10.1.0."), "NAT address \(nat)")
      let segmentNIC = try await lab.exec(
        "node-1", "ip -o link | grep -i \(a.mac) | awk -F': ' '{print $2}'"
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(!segmentNIC.isEmpty)
      #expect(route.contains("dev \(segmentNIC) "), "\(route) (segment NIC \(segmentNIC))")

      // R-902 Verify (integration): `ping node-2.cluster` resolves on node-1, and a leave
      // removes the name.
      let named = try await lab.exec("node-1", "ping -c 1 -W 2 node-2.cluster")
      #expect(named.exitCode == 0, "\(named.stdout)\(named.stderr)")
      #expect(named.stdout.contains(b.address), "\(named.stdout)")
      let plain = try await lab.exec("node-2", "getent hosts node-1")
      #expect(plain.stdout.hasPrefix(a.address), "\(plain.stdout)")
      try await lab.manager.perform(.destroy, on: "node-2")
      let gone = try await lab.exec("node-1", "getent hosts node-2.cluster; cat /etc/hosts")
      #expect(!gone.stdout.contains(b.address), "\(gone.stdout)")
      #expect(gone.stdout.contains("\(a.address) node-1 node-1.cluster"), "\(gone.stdout)")
    } catch {
      await lab.shutdown()
      throw error
    }
    await lab.shutdown()
  }

  /// R-901 Verify (integration): a VZ Linux guest and a QEMU guest on one segment ping.
  @Test(.enabled(if: VZRunnerIntegrationTests.ready), .timeLimit(.minutes(10)))
  func vzAndQEMUGuestsPing() async throws {
    let lab = try LabHome(tag: "v")
    do {
      let network = NetworkSpec(mode: .nat, segment: "mixed")
      let features: [Feature] = [.serial, .execSSH, .netNAT, .netSegment]
      async let q = lab.boot(
        name: "q", plan: LabHome.plan(features: features), network: network)
      async let v = lab.boot(
        name: "v", plan: LabHome.plan(.vzLinux, features: features), network: network)
      let (qemu, vz) = try await (q, v)
      #expect(qemu.warnings.isEmpty && vz.warnings.isEmpty, "\(qemu.warnings) \(vz.warnings)")
      let qa = try #require(qemu.record?.segment?.address)
      let va = try #require(vz.record?.segment?.address)
      let ping = try await lab.exec("v", "ping -c 3 -W 2 \(qa)")
      #expect(ping.exitCode == 0, "\(ping.stdout)\(ping.stderr)")
      let back = try await lab.exec("q", "ping -c 3 -W 2 \(va)")
      #expect(back.exitCode == 0, "\(back.stdout)\(back.stderr)")
    } catch {
      await lab.shutdown()
      throw error
    }
    await lab.shutdown()
  }

  /// R-901 Verify (integration), the macOS part: a vz-macos guest gets its static segment address
  /// from `networksetup` in provisioning and pings a QEMU guest on the same segment.
  @Test(
    .enabled(if: VZMacGuestIntegrationTests.ready && VZMacGuestIntegrationTests.hostHasRoom()),
    .timeLimit(.minutes(15)))
  func macOSAndQEMUGuestsPing() async throws {
    let lab = try LabHome(tag: "m")
    do {
      let network = NetworkSpec(mode: .nat, segment: "macmix")
      let features: [Feature] = [.execSSH, .netNAT, .netSegment]
      let qemu = try await lab.boot(
        name: "q", plan: LabHome.plan(features: features + [.serial]), network: network)
      let macPlan = Plan(
        profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
        resources: ResourceSpec(cpus: 4, memoryGB: 4), features: features,
        requested: features, estimatedStartupSeconds: 60)
      let mac = try await lab.boot(
        name: "mac", image: "macos-base", plan: macPlan, network: network)
      #expect(qemu.warnings.isEmpty, "\(qemu.warnings)")
      #expect(mac.warnings.allSatisfy { !$0.hasPrefix("ssh_unreachable") }, "\(mac.warnings)")
      let qa = try #require(qemu.record?.segment?.address)
      let ma = try #require(mac.record?.segment?.address)
      let macID = try #require(mac.record?.id)
      let report = try #require(ProvisionReport.load(from: lab.store.directory(of: macID)))
      #expect(report.steps.contains { $0.name == "segment_address" && $0.status == .succeeded })
      let address = try await lab.exec("mac", "ifconfig | grep 'inet \(ma) '")
      #expect(address.exitCode == 0, "\(address.stdout)\(address.stderr)")
      let ping = try await lab.exec("mac", "ping -c 3 -t 10 \(qa)")
      #expect(ping.exitCode == 0, "\(ping.stdout)\(ping.stderr)")
      let back = try await lab.exec("q", "ping -c 3 -W 2 \(ma)")
      #expect(back.exitCode == 0, "\(back.stdout)\(back.stderr)")
    } catch {
      await lab.shutdown()
      throw error
    }
    await lab.shutdown()
  }
}
