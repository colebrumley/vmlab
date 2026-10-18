import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// The configuration builder's decisions for a `VMRecord`, snapshotted as JSON. Set
/// `VMLAB_RECORD_SNAPSHOTS=1` to rewrite the snapshot files after an intended change.
@Suite struct MachineDecisionsTests {
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/vz")
  static let dir = URL(filePath: "/vmlab/vms/vm-test01")
  static let limits = VZMachineLimits(
    minCPUs: 1, maxCPUs: 10, minMemoryBytes: 1 << 29, maxMemoryBytes: 16 << 30)

  static func record(
    features: [Feature] = [.execSSH, .serial], resources: ResourceSpec = ResourceSpec(),
    network: NetworkSpec = NetworkSpec()
  ) -> VMRecord {
    VMRecord(
      id: "vm-test01", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      features: features, resources: resources, image: "debian-13-arm64", network: network)
  }

  static func assertSnapshot(_ decisions: VZMachineDecisions, _ name: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let text = String(decoding: try encoder.encode(decisions), as: UTF8.self) + "\n"
    let file = fixtures.appending(path: name)
    if ProcessInfo.processInfo.environment["VMLAB_RECORD_SNAPSHOTS"] == "1" {
      try text.write(to: file, atomically: true, encoding: .utf8)
    }
    #expect(text == (try String(contentsOf: file, encoding: .utf8)))
  }

  @Test func headlessLinuxGuest() throws {
    let config = try VZRunnerConfig.linux(record: Self.record(), vmDirectory: Self.dir)
    let decisions = try config.decisions(limits: Self.limits)
    try Self.assertSnapshot(decisions, "decisions-linux.json")
    #expect(decisions.cpus == 2)
    #expect(decisions.memoryBytes == 4 << 30)
    #expect(decisions.bootLoader == .efi(variableStore: "/vmlab/vms/vm-test01/efi-vars.bin"))
    #expect(
      decisions.storage == [
        .init(path: "/vmlab/vms/vm-test01/disk.raw", readOnly: false),
        .init(path: "/vmlab/vms/vm-test01/seed.iso", readOnly: true),
      ])
    #expect(decisions.network.map(\.mac) == [VZRunnerConfig.stableMAC(for: "vm-test01")])
    #expect(decisions.console?.log == "/vmlab/vms/vm-test01/console.log")
    #expect(decisions.console?.socket == "/vmlab/vms/vm-test01/serial.sock")
    #expect(decisions.entropy && decisions.memoryBalloon)
    #expect(decisions.graphics == nil)
  }

  /// `VZVirtioGraphicsDevice` only when `gui` was granted.
  @Test func graphicsOnlyWithGUI() throws {
    let config = try VZRunnerConfig.linux(
      record: Self.record(features: [.execSSH, .serial, .gui, .guiDesktop]),
      vmDirectory: Self.dir)
    let decisions = try config.decisions(limits: Self.limits)
    try Self.assertSnapshot(decisions, "decisions-linux-gui.json")
    #expect(decisions.graphics == .init(width: 1280, height: 800))
    let desktopOnly = try VZRunnerConfig.linux(
      record: Self.record(features: [.guiDesktop]), vmDirectory: Self.dir)
    #expect(try desktopOnly.decisions(limits: Self.limits).graphics == nil)
  }

  /// R-603: the share becomes the virtiofs device `share0`; Rosetta only when the plan asked.
  @Test func sharesAndRosettaAreVirtiofsDevices() throws {
    var record = Self.record(features: [.execSSH, .serial, .sharedDir, .rosetta])
    record.share = SharedDirSpec(host: "/Users/me/src", guest: "/src")
    #expect(
      try VZRunnerConfig.linux(record: record, vmDirectory: Self.dir).decisions(limits: Self.limits)
        .fileSystems == [
          .init(tag: "share0", path: "/Users/me/src", readOnly: false)
        ])
    record.plan = Plan(
      profile: .vzLinux, guest: record.guest, resources: record.resources,
      features: record.features, requested: [.sharedDir, .rosetta], estimatedStartupSeconds: 30)
    let decisions = try VZRunnerConfig.linux(record: record, vmDirectory: Self.dir)
      .decisions(limits: Self.limits)
    try Self.assertSnapshot(decisions, "decisions-linux-share-rosetta.json")
    #expect(
      decisions.fileSystems.last == .init(tag: "rosetta", path: nil, readOnly: true, rosetta: true))
  }

  /// R-609: nested virtualization only when the plan asked for `nested_virt`.
  @Test func nestedVirtualizationOnlyWhenRequested() throws {
    var record = Self.record(features: [.execSSH, .nestedVirt])
    #expect(
      !(try VZRunnerConfig.linux(record: record, vmDirectory: Self.dir).decisions(
        limits: Self.limits
      ).nestedVirtualization))
    record.plan = Plan(
      profile: .vzLinux, guest: record.guest, resources: record.resources,
      features: record.features, requested: [.nestedVirt], estimatedStartupSeconds: 30)
    #expect(
      try VZRunnerConfig.linux(record: record, vmDirectory: Self.dir).decisions(
        limits: Self.limits
      ).nestedVirtualization)
  }

  /// A config written before R-603 (no share keys) still decodes.
  @Test func olderConfigDecodes() throws {
    let config = try VZRunnerConfig.linux(record: Self.record(), vmDirectory: Self.dir)
    let encoder = JSONEncoder()
    var object = try #require(
      try JSONSerialization.jsonObject(with: encoder.encode(config)) as? [String: Any])
    object["directoryShares"] = nil
    object["rosetta"] = nil
    object["serialSocket"] = nil
    let old = try JSONDecoder().decode(
      VZRunnerConfig.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.directoryShares.isEmpty && !old.rosetta && old.serialSocket == nil)
  }

  @Test func kernelBootUsesTheLinuxLoader() throws {
    let config = try VZRunnerConfig.linux(
      record: Self.record(), vmDirectory: Self.dir,
      boot: BootSpec(mode: .kernel, kernel: "/k/Image", initrd: "/k/initrd"), seed: false)
    let decisions = try config.decisions(limits: Self.limits)
    #expect(
      decisions.bootLoader
        == .linux(
          kernel: "/k/Image", initrd: "/k/initrd", commandLine: VZRunnerConfig.defaultCommandLine))
    #expect(decisions.storage.map(\.path) == ["/vmlab/vms/vm-test01/disk.raw"])
  }

  @Test func firmwareAndKernellessBootAreRefused() {
    for boot in [BootSpec(mode: .firmware, firmware: "/f.fd"), BootSpec(mode: .kernel)] {
      #expect {
        try VZRunnerConfig.linux(record: Self.record(), vmDirectory: Self.dir, boot: boot)
      } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
    }
  }

  @Test func noNetworkMeansNoNIC() throws {
    let config = try VZRunnerConfig.linux(
      record: Self.record(network: NetworkSpec(mode: .disabled)), vmDirectory: Self.dir)
    #expect(try config.decisions(limits: Self.limits).network.isEmpty)
  }

  @Test func resourcesAreClampedToTheFrameworkLimits() throws {
    var config = try VZRunnerConfig.linux(
      record: Self.record(resources: ResourceSpec(cpus: 64, memoryGB: 64)), vmDirectory: Self.dir)
    var decisions = try config.decisions(limits: Self.limits)
    #expect(decisions.cpus == 10)
    #expect(decisions.memoryBytes == 16 << 30)
    config.cpus = 0
    config.memoryBytes = (1 << 30) + 12345  // rounded down to whole MiB
    decisions = try config.decisions(limits: Self.limits)
    #expect(decisions.cpus == 1)
    #expect(decisions.memoryBytes == 1 << 30)
  }

  @Test func badMACIsInvalidRequestAndMACsAreNormalised() throws {
    var config = try VZRunnerConfig.linux(record: Self.record(), vmDirectory: Self.dir)
    config.network = [.nat(macAddress: "2:A:3b:4c:5d:6e"), .nat(macAddress: nil)]
    #expect(
      try config.decisions(limits: Self.limits).network.map(\.mac) == ["02:0a:3b:4c:5d:6e", nil])
    config.network = [.nat(macAddress: "nope")]
    #expect {
      try config.decisions(limits: Self.limits)
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
  }

  /// Stable per id, unicast and locally administered.
  @Test func stableMACIsStableLocalAndUnicast() throws {
    let mac = VZRunnerConfig.stableMAC(for: "vm-abc234")
    #expect(mac == VZRunnerConfig.stableMAC(for: "vm-abc234"))
    #expect(mac != VZRunnerConfig.stableMAC(for: "vm-abc235"))
    #expect(MACAddress.normalize(mac) == mac)
    let first = try #require(UInt8(mac.prefix(2), radix: 16))
    #expect(first & 0x01 == 0)
    #expect(first & 0x02 == 0x02)
  }

  /// The config file round-trips, so what the server writes is what the runner reads.
  @Test func configRoundTripsThroughDisk() throws {
    let config = try VZRunnerConfig.linux(
      record: Self.record(features: [.gui]), vmDirectory: Self.dir)
    let file = FileManager.default.temporaryDirectory.appending(path: "vz-config-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try config.write(to: file)
    #expect(try VZRunnerConfig.read(from: file) == config)
  }
}

extension MachineDecisionsTests {
  /// R-901: a segment member gets a second NIC after NAT, on the switch's attach socket.
  @Test func segmentNICFollowsNAT() throws {
    var record = Self.record()
    record.segment = SegmentAttachment(
      segment: "lab", address: "10.1.0.10", mac: SegmentAttachment.mac(for: "vm-test01"))
    let config = try VZRunnerConfig.linux(
      record: record, vmDirectory: Self.dir, segmentAttachSocket: "/vmlab/segments/lab/attach.sock")
    let decisions = try config.decisions(limits: Self.limits)
    #expect(decisions.network.count == 1)
    #expect(
      decisions.segment
        == .init(
          mac: SegmentAttachment.mac(for: "vm-test01"),
          attachSocket: "/vmlab/segments/lab/attach.sock"))
    let plain = try VZRunnerConfig.linux(record: Self.record(), vmDirectory: Self.dir)
    #expect(try plain.decisions(limits: Self.limits).segment == nil)
  }
}
