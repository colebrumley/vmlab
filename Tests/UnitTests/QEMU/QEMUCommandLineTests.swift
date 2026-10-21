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

  /// A comma in the VM directory is escaped as ",," in every QEMU option that names a path,
  /// the QMP and VNC sockets included (they split the option there otherwise).
  @Test func commasInSocketPathsAreEscaped() throws {
    let record = try Self.record("tcg-arm64")
    let layout = QEMULayout(vmDirectory: URL(filePath: "/Users/a,b/.vmlab/vms/\(record.id)"))
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: layout,
      options: QEMULaunchOptions(firmware: Self.firmware))
    let qmp = args.indices.filter { args[$0] == "-qmp" }.map { args[$0 + 1] }
    #expect(qmp.count == 2)
    #expect(qmp.allSatisfy { $0.hasPrefix("unix:/Users/a,,b/") })
    #expect(
      args.firstIndex(of: "-vnc").map { args[$0 + 1] }?.hasPrefix("unix:/Users/a,,b/") == true)
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

  /// The request's -cpu replaces vmlab's and its -machine properties join vmlab's -machine;
  /// neither is appended again.
  static func customArgs(_ fixture: String, _ qemuArgs: [String]) throws -> [String] {
    var record = try record(fixture)
    record.extra = ExtraSpec(qemuArgs: qemuArgs)
    record.features.append(.customDevices)
    return try QEMUCommandLine.arguments(
      record: record, plan: plan(for: record), layout: layout(record),
      options: QEMULaunchOptions(firmware: firmware, gdbPort: 41234))
  }

  @Test func cpuAndMachineReplaceVmlabsOwn() throws {
    let hvf = try Self.customArgs(
      "hvf", ["-cpu", "host,pmu=off", "-machine", "highmem=off,dumpdtb=/tmp/a,,b.dtb", "-usb"])
    #expect(
      Array(hvf.prefix(10)) == [
        "-name", "vmlab-\(try Self.record("hvf").id)", "-nodefaults", "-no-user-config",
        "-machine", "virt,highmem=off,dumpdtb=/tmp/a,,b.dtb", "-accel", "hvf", "-cpu",
        "host,pmu=off",
      ])
    #expect(hvf.filter { $0 == "-cpu" }.count == 1 && hvf.filter { $0 == "-machine" }.count == 1)
    #expect(hvf.last == "-usb")

    let tcg = try Self.customArgs(
      "tcg-arm64", ["-M", "sbsa-ref,secure=on", "-cpu", "cortex-a72,pmu=on", "-icount", "auto"])
    #expect(tcg[tcg.firstIndex(of: "-machine")! + 1] == "sbsa-ref,secure=on")
    #expect(tcg[tcg.firstIndex(of: "-cpu")! + 1] == "cortex-a72,pmu=on")
    #expect(tcg.filter { $0 == "-cpu" }.count == 1)
    #expect(Array(tcg.suffix(2)) == ["-icount", "auto"])

    // vmlab's own defaults stand when the request names neither.
    let plain = try Self.customArgs("hvf", ["-usb"])
    #expect(plain[plain.firstIndex(of: "-machine")! + 1] == "virt")
    #expect(plain[plain.firstIndex(of: "-cpu")! + 1] == "host")
  }

  /// What contradicts the profile is invalid_request naming the argument.
  @Test(arguments: [
    ("hvf", ["-cpu", "cortex-a72"], 1),
    ("hvf", ["-usb", "-machine", "raspi3b"], 2),
    ("hvf", ["-icount", "shift=auto"], -1),
    ("tcg-arm64", ["-cpu", "host"], 1),
  ])
  func profileContradictionsAreRefused(fixture: String, qemuArgs: [String], index: Int) {
    #expect {
      _ = try Self.customArgs(fixture, qemuArgs)
    } throws: { error in
      guard let error = error as? VMLabError, error.code == .invalidRequest else { return false }
      let field = index < 0 ? "extra.qemuArgs" : "extra.qemuArgs[\(index)]"
      // R-1204: the way out is an emulated CPU, which the model asks for by feature.
      if fixture == "hvf", !error.hint.contains("require cpu_emulation") { return false }
      return error.data["field"] == .string(field)
    }
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
    // -kernel takes boot index 0 on x86; the disk must not claim it too.
    #expect(args.contains("virtio-blk-pci,drive=disk0"))
    #expect(!args.contains { $0.contains("bootindex") })
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

  /// R-404: a shared directory is `-virtfs` with tag share0, and needs shared_dir in the plan.
  @Test func sharedDirectoryIsVirtfs() throws {
    var record = try Self.record("hvf")
    record.features.append(.sharedDir)
    let options = QEMULaunchOptions(
      firmware: Self.firmware, gdbPort: 1234, sharedDirectory: "/Users/me/a,b")
    let args = try QEMUCommandLine.arguments(
      record: record, plan: Self.plan(for: record), layout: Self.layout(record), options: options)
    let index = try #require(args.firstIndex(of: "-virtfs"))
    #expect(
      args[index + 1]
        == "local,path=/Users/me/a,,b,mount_tag=share0,security_model=mapped-xattr,id=share0")
    record.features.removeAll { $0 == .sharedDir }
    #expect(throws: VMLabError.self) {
      try QEMUCommandLine.arguments(
        record: record, plan: Self.plan(for: record), layout: Self.layout(record),
        options: options)
    }
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

  /// R-1202: a bare machine's launch (`QEMUBackend.request`, then the options `launch` uses) has
  /// no `-drive`, no seed and no guest-agent chardev, but keeps `ramfb` and the input devices.
  @Test func aBareMachineHasNoDriveSeedOrAgent() async throws {
    // Short: the QMP socket path must fit sun_path.
    let home = URL(filePath: "/tmp/vqb-\(UInt32.random(in: 0...UInt32.max))")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let kernel = home.appending(path: "kernel.bin")
    try Data([0]).write(to: kernel)
    let requirements = try Requirements(
      guest: GuestSpec(os: .linux, arch: .arm64), require: [.serial, .gdb],
      prefer: [.execAgent, .guiPreboot], image: "none",
      boot: BootSpec(mode: .kernel, kernel: kernel.path))
    let plan = try ProfileSelector.select(
      requirements, host: SelectorTests.devHost(), running: .empty
    ).get()
    #expect(plan.profile == .qemuHVF && !plan.grants(.execAgent))
    let record = VMRecord(
      id: "vm-bare01", profile: plan.profile, guest: plan.guest, features: plan.features,
      resources: plan.resources, boot: requirements.boot)
    #expect(record.isBare)
    let backend = QEMUBackend(
      profile: .qemuHVF, store: Store(home: home),
      installation: QEMUInstallation(
        binDirectory: home.appending(path: "bin"), shareDirectory: home.appending(path: "share")))
    var request = try await backend.request(record, plan: plan, seed: true)
    #expect(request.baseImage == nil && request.seed == nil)
    request.gdbPort = 41234
    let args = try QEMUCommandLine.arguments(
      record: record, plan: plan, layout: backend.layout(of: record.id),
      options: try request.options())
    #expect(!args.contains("-drive"))
    #expect(
      !args.contains { $0.contains("qga0") || $0.contains("disk.qcow2") || $0.contains("seed") })
    #expect(args.contains("ramfb") && args.contains("usb-tablet"))
    #expect(args.firstIndex(of: "-kernel").map { args[$0 + 1] } == kernel.path)
  }
}
