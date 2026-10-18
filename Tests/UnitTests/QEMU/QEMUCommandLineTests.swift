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
