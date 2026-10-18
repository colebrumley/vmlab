import Foundation
import Testing
import VMLabCore

@testable import VMLabQEMU

@Suite struct QEMUCommandLineTests {
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/qemu")
  static let firmware = QEMUFirmware(
    code: "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
    varsTemplate: "/opt/homebrew/share/qemu/edk2-arm-vars.fd")

  static func record(_ name: String) throws -> VMRecord {
    let data = try Data(contentsOf: fixtures.appending(path: "\(name).vm.json"))
    return try StoreMigrations.released.decode(data, source: name)
  }

  static func plan(for record: VMRecord) -> Plan {
    Plan(
      profile: record.profile, guest: record.guest,
      resources: ResourceLimits.resolve(record.resources, for: record.guest.os),
      features: record.features, estimatedStartupSeconds: 10)
  }

  static func layout(_ record: VMRecord) -> QEMULayout {
    QEMULayout(vmDirectory: URL(filePath: "/Users/someone/.vmlab/vms/\(record.id)"))
  }

  /// One snapshot per profile (and per arch under TCG): the argument array, one per line.
  @Test(arguments: [
    ("hvf", QEMULaunchOptions(firmware: firmware, seed: true, gdbPort: 41234, sshHostPort: 52222)),
    ("tcg-arm64", QEMULaunchOptions(firmware: firmware, seed: true)),
    (
      "tcg-x86_64",
      QEMULaunchOptions(
        firmware: QEMUFirmware(
          code: "/opt/homebrew/share/qemu/edk2-x86_64-code.fd",
          varsTemplate: "/opt/homebrew/share/qemu/edk2-i386-vars.fd"),
        gdbPort: 1234, sshHostPort: 2222)
    ),
    (
      "tcg-riscv64",
      QEMULaunchOptions(
        firmware: QEMUFirmware(
          code: "/opt/homebrew/share/qemu/edk2-riscv-code.fd",
          varsTemplate: "/opt/homebrew/share/qemu/edk2-riscv-vars.fd"),
        sshHostPort: 2222)
    ),
    (
      "tcg-other",
      QEMULaunchOptions(
        boot: BootSpec(mode: .kernel, kernel: "/k/vmlinux", cmdline: "console=hvc0"), disk: false)
    ),
  ])
  func snapshot(name: String, options: QEMULaunchOptions) throws {
    let record = try Self.record(name)
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record), options: options)
    let text = args.joined(separator: "\n") + "\n"
    let snapshot = Self.fixtures.appending(path: "\(name).args")
    if ProcessInfo.processInfo.environment["VMLAB_UPDATE_SNAPSHOTS"] == "1" {
      try Data(text.utf8).write(to: snapshot)
    }
    let expected = try String(contentsOf: snapshot, encoding: .utf8)
    #expect(text == expected)
  }

  /// R-305: one snapshot per boot mode.
  @Test(arguments: [
    (
      "boot-kernel", "hvf",
      QEMULaunchOptions(
        boot: BootSpec(
          mode: .kernel, kernel: "/k/vmlinuz", initrd: "/k/initrd.img",
          cmdline: "console=ttyAMA0 root=/dev/vda1", dtb: "/k/virt.dtb"),
        seed: true, gdbPort: 41234, sshHostPort: 52222)
    ),
    (
      "boot-firmware-pflash", "tcg-arm64",
      QEMULaunchOptions(
        boot: BootSpec(mode: .firmware, firmware: "/fw/my,uefi.fd"), firmware: firmware)
    ),
    (
      "boot-firmware-bios", "tcg-x86_64",
      QEMULaunchOptions(
        boot: BootSpec(mode: .firmware, firmware: "/fw/seabios.bin", firmwareFormat: .bios),
        gdbPort: 1234, sshHostPort: 2222)
    ),
    (
      "boot-binary", "tcg-arm64",
      QEMULaunchOptions(
        boot: BootSpec(mode: .binary, binary: "/bm/kernel.bin", loadAddress: "0x40080000"),
        disk: false)
    ),
  ])
  func bootSnapshot(name: String, fixture: String, options: QEMULaunchOptions) throws {
    let record = try Self.record(fixture)
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record), options: options)
    let text = args.joined(separator: "\n") + "\n"
    let snapshot = Self.fixtures.appending(path: "\(name).args")
    if ProcessInfo.processInfo.environment["VMLAB_UPDATE_SNAPSHOTS"] == "1" {
      try Data(text.utf8).write(to: snapshot)
    }
    let expected = try String(contentsOf: snapshot, encoding: .utf8)
    #expect(text == expected)
  }

  @Test func bootModesPickTheirFlags() throws {
    let record = try Self.record("tcg-arm64")
    func args(_ boot: BootSpec, disk: Bool = true) throws -> [String] {
      try QEMUCommandLine.arguments(
        record: record, plan: Self.plan(for: record), layout: Self.layout(record),
        options: QEMULaunchOptions(boot: boot, firmware: Self.firmware, disk: disk))
    }
    let bios = try args(BootSpec(mode: .firmware, firmware: "/fw/rom", firmwareFormat: .bios))
    #expect(bios.firstIndex(of: "-bios").map { bios[$0 + 1] } == "/fw/rom")
    #expect(!bios.contains { $0.hasPrefix("if=pflash") })
    let pflash = try args(BootSpec(mode: .firmware, firmware: "/fw/a,b.fd"))
    #expect(pflash.contains("if=pflash,format=raw,unit=0,readonly=on,file=/fw/a,,b.fd"))
    #expect(pflash.contains { $0.hasPrefix("if=pflash,format=raw,unit=1,") })
    let binary = try args(
      BootSpec(mode: .binary, binary: "/b.bin", loadAddress: "1074266112"), disk: false)
    #expect(binary.contains("loader,file=/b.bin,addr=0x40080000,cpu-num=0,force-raw=on"))
    #expect(!binary.contains { $0.contains("id=disk0") })
    #expect(!binary.contains { $0.hasPrefix("if=pflash") })
    let kernel = try args(BootSpec(mode: .kernel, kernel: "/k", dtb: "/d.dtb"))
    #expect(kernel.firstIndex(of: "-dtb").map { kernel[$0 + 1] } == "/d.dtb")
    #expect(throws: VMLabError.self) { try args(BootSpec(mode: .kernel)) }
  }

  /// R-306: extra.qemuArgs are appended verbatim, last, when the plan grants custom_devices.
  @Test func customDevicesPassThroughLast() throws {
    var record = try Self.record("tcg-arm64")
    record.extra = ExtraSpec(qemuArgs: ["-device", "virtio-rng-pci", "-global", "a.b=c,d"])
    record.features.append(.customDevices)
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record),
      options: QEMULaunchOptions(firmware: Self.firmware))
    #expect(Array(args.suffix(4)) == ["-device", "virtio-rng-pci", "-global", "a.b=c,d"])
    #expect(args.firstIndex(of: "-S")! < args.count - 4)

    record.features.removeAll { $0 == .customDevices }
    #expect {
      try QEMUCommandLine.arguments(
        record: record, plan: Self.plan(for: record), layout: Self.layout(record),
        options: QEMULaunchOptions(firmware: Self.firmware))
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }

    record.features.append(.customDevices)
    record.extra = ExtraSpec(qemuArgs: ["-monitor", "stdio"])
    #expect {
      try QEMUCommandLine.arguments(
        record: record, plan: Self.plan(for: record), layout: Self.layout(record),
        options: QEMULaunchOptions(firmware: Self.firmware))
    } throws: { ($0 as? VMLabError)?.data["field"] == .string("extra.qemuArgs[0]") }
  }

  /// R-308: user-mode NIC with the SSH forward and every requested forward, ephemeral ones
  /// resolved; net_none has no NIC at all.
  @Test func userNetworkingSnapshot() throws {
    var record = try Self.record("hvf")
    record.network.forwards = [PortForward(guest: 80, host: 8080), PortForward(guest: 443)]
    let forwards = try QEMUBackend.resolveForwards(record.network.forwards, freePort: { 49152 })
    #expect(forwards == [PortForward(guest: 80, host: 8080), PortForward(guest: 443, host: 49152)])
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record),
      options: QEMULaunchOptions(
        firmware: Self.firmware, gdbPort: 41234, sshHostPort: 52222, forwards: forwards))
    let text = args.joined(separator: "\n") + "\n"
    let snapshot = Self.fixtures.appending(path: "net-forwards.args")
    if ProcessInfo.processInfo.environment["VMLAB_UPDATE_SNAPSHOTS"] == "1" {
      try Data(text.utf8).write(to: snapshot)
    }
    #expect(text == (try String(contentsOf: snapshot, encoding: .utf8)))
    let netdev = try #require(args.firstIndex(of: "-netdev").map { args[$0 + 1] })
    #expect(
      netdev
        == "user,id=net0,hostfwd=tcp:127.0.0.1:52222-:22,hostfwd=tcp:127.0.0.1:8080-:80,"
        + "hostfwd=tcp:127.0.0.1:49152-:443")

    // Unresolved ephemeral forwards are a bug, not a silently dropped forward.
    #expect(throws: VMLabError.self) {
      try QEMUCommandLine.arguments(
        record: record, plan: Self.plan(for: record), layout: Self.layout(record),
        options: QEMULaunchOptions(firmware: Self.firmware, gdbPort: 1))
    }

    var none = try Self.record("tcg-arm64")
    none.network = NetworkSpec(mode: .disabled)
    let offline = try QEMUCommandLine.arguments(
      record: none, plan: Self.plan(for: none), layout: Self.layout(none),
      options: QEMULaunchOptions(firmware: Self.firmware, sshHostPort: 2222))
    #expect(offline.firstIndex(of: "-nic").map { offline[$0 + 1] } == "none")
    #expect(!offline.contains("-netdev") && !offline.contains { $0.contains("hostfwd") })
  }

  @Test func ephemeralForwardsGetDistinctPorts() throws {
    var ports = [5000, 5000, 8080, 5001]
    let resolved = try QEMUBackend.resolveForwards(
      [PortForward(guest: 1), PortForward(guest: 2, host: 8080), PortForward(guest: 3)],
      freePort: { ports.removeFirst() })
    #expect(resolved.map(\.host) == [5000, 8080, 5001])
  }

  @Test func alwaysHaltedDaemonizedAndHeadless() throws {
    let record = try Self.record("hvf")
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record),
      options: QEMULaunchOptions(firmware: Self.firmware, gdbPort: 1))
    for flag in ["-S", "-daemonize", "-pidfile"] { #expect(args.contains(flag)) }
    #expect(args.contains("hvf") && args.contains("host"))
    #expect(args.contains("ramfb") && !args.contains("virtio-gpu-pci"))
    for device in ["usb-kbd", "usb-tablet", "virtio-keyboard-pci", "virtio-tablet-pci"] {
      #expect(args.contains(device))
    }
    #expect(args.firstIndex(of: "-display").map { args[$0 + 1] } == "none")
  }

  @Test func gdbOnlyWhenGranted() throws {
    var record = try Self.record("hvf")
    record.features.removeAll { $0 == .gdb }
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record),
      options: QEMULaunchOptions(firmware: Self.firmware, gdbPort: 1234))
    #expect(!args.contains("-gdb"))
  }

  @Test func gdbGrantedWithoutPortIsABug() throws {
    let record = try Self.record("hvf")
    #expect(throws: VMLabError.self) {
      try QEMUCommandLine.arguments(
        record: record, plan: Self.plan(for: record), layout: Self.layout(record),
        options: QEMULaunchOptions(firmware: Self.firmware))
    }
  }

  @Test func kernelBootSkipsFirmware() throws {
    let record = try Self.record("tcg-arm64")
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record),
      options: QEMULaunchOptions(
        boot: BootSpec(mode: .kernel, kernel: "/k/vmlinuz", initrd: "/k/initrd", cmdline: "quiet")))
    #expect(!args.contains { $0.hasPrefix("if=pflash") })
    #expect(args.contains("/k/vmlinuz") && args.contains("/k/initrd") && args.contains("quiet"))
  }

  /// R-310: per-architecture binaries, machines and defaults; TCG caps -smp at 8.
  @Test func architectureDefaults() throws {
    #expect(QEMUCommandLine.target(for: .riscv64) == "riscv64")
    #expect(QEMUCommandLine.target(for: .other("ppc64")) == "ppc64")
    #expect(QEMUCommandLine.target(for: .other("../sh")) == nil)
    #expect(QEMUCommandLine.machine(for: .x86_64) == "q35")
    #expect(QEMUCommandLine.machine(for: .other("ppc64")) == "virt")
    let installation = QEMUInstallation(
      binDirectory: URL(filePath: "/opt/homebrew/bin"),
      shareDirectory: URL(filePath: "/opt/homebrew/share/qemu"))
    #expect(installation.systemBinary(for: .riscv64).lastPathComponent == "qemu-system-riscv64")
    #expect(
      installation.systemBinary(for: .other("ppc64")).lastPathComponent == "qemu-system-ppc64")

    let riscv = try Self.record("tcg-riscv64")
    let args = try QEMUCommandLine.arguments(
      record: riscv, plan: Self.plan(for: riscv), layout: Self.layout(riscv),
      options: QEMULaunchOptions(firmware: Self.firmware, sshHostPort: 1))
    #expect(args.firstIndex(of: "-smp").map { args[$0 + 1] } == "8")

    let other = try Self.record("tcg-other")
    let bare = try QEMUCommandLine.arguments(
      record: other, plan: Self.plan(for: other), layout: Self.layout(other),
      options: QEMULaunchOptions(boot: BootSpec(mode: .kernel, kernel: "/k"), disk: false))
    #expect(!bare.contains("-cpu") && !bare.contains("ramfb") && !bare.contains("usb-kbd"))
    #expect(bare.firstIndex(of: "-machine").map { bare[$0 + 1] } == "virt")
    #expect {
      try QEMUCommandLine.arguments(
        record: other, plan: Self.plan(for: other), layout: Self.layout(other),
        options: QEMULaunchOptions(disk: false))
    } throws: { ($0 as? VMLabError)?.data["field"] == .string("boot.mode") }
  }

  @Test func hvfRefusesX86() throws {
    var record = try Self.record("tcg-x86_64")
    record.profile = .qemuHVF
    #expect {
      try QEMUCommandLine.arguments(
        record: record, plan: Self.plan(for: record), layout: Self.layout(record),
        options: QEMULaunchOptions(firmware: Self.firmware, gdbPort: 1))
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
  }

  @Test func longSocketPathsAreRefused() throws {
    let record = try Self.record("tcg-arm64")
    let deep = "/" + String(repeating: "d", count: 90) + "/vms/\(record.id)"
    #expect {
      try QEMUCommandLine.arguments(
        record: record, plan: Self.plan(for: record),
        layout: QEMULayout(vmDirectory: URL(filePath: deep)),
        options: QEMULaunchOptions(firmware: Self.firmware))
    } throws: {
      guard let error = $0 as? VMLabError else { return false }
      return error.code == .invalidRequest && error.data["field"] == .string("VMLAB_HOME")
    }
  }

  @Test func macIsStableAndLocal() {
    let mac = QEMUCommandLine.mac(for: "vm-abc234")
    #expect(mac == QEMUCommandLine.mac(for: "vm-abc234"))
    #expect(mac != QEMUCommandLine.mac(for: "vm-abc235"))
    #expect(mac.hasPrefix("52:54:00:") && mac.count == 17)
  }
}

extension QEMUCommandLineTests {
  /// R-901: the segment NIC is `-netdev dgram` from the guest's port socket to the switch.
  @Test func segmentNICIsADgramNetdev() throws {
    let record = try Self.record("hvf")
    let options = QEMULaunchOptions(
      firmware: Self.firmware, gdbPort: 41234, sshHostPort: 2222,
      segment: QEMUSegmentNIC(
        portSocket: "/h/segments/lab/ports/\(record.id).sock",
        switchSocket: "/h/segments/lab/switch.sock", mac: "52:54:5e:01:02:03"))
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record), options: options)
    let netdev = try #require(
      args.firstIndex(
        of:
          "dgram,id=net1,local.type=unix,local.path=/h/segments/lab/ports/\(record.id).sock,remote.type=unix,remote.path=/h/segments/lab/switch.sock"
      ))
    #expect(args[netdev - 1] == "-netdev")
    #expect(args[netdev + 2] == "virtio-net-pci,netdev=net1,mac=52:54:5e:01:02:03")
    // After the NAT NIC.
    #expect(args.firstIndex(of: "-netdev")! < netdev - 1)
  }
}
