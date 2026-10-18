import Foundation
import VMLabCore

/// What a launch needs beyond the record and the plan.
public struct QEMULaunchOptions: Sendable, Hashable {
  public var boot: BootSpec
  /// UEFI code and vars for `.disk` boot (and the vars of a custom pflash firmware).
  public var firmware: QEMUFirmware?
  /// Whether `disk.qcow2` is attached; false for a kernel-only or bare-metal guest with no image.
  public var disk: Bool
  /// Whether `seed.iso` is attached as a second virtio disk.
  public var seed: Bool
  /// The loopback TCP port for `-gdb` when the plan grants `gdb`.
  public var gdbPort: Int?
  /// The loopback TCP port forwarded to the guest's port 22.
  public var sshHostPort: Int?
  /// The request's forwards with every host port chosen (R-308); nil uses the record's, which
  /// must then all name a host port.
  public var forwards: [PortForward]?
  /// `net_fast` (R-309): the NIC is `vmnet-shared` (root or the `qemu_vmnet` probe) instead of
  /// user-mode networking. The guest is then reached on its own address; nothing is forwarded.
  public var vmnet: Bool
  /// The second NIC on a segment (R-901): `-netdev dgram` between its port socket and the switch.
  public var segment: QEMUSegmentNIC?

  public init(
    boot: BootSpec = BootSpec(), firmware: QEMUFirmware? = nil, disk: Bool = true,
    seed: Bool = false, gdbPort: Int? = nil, sshHostPort: Int? = nil,
    forwards: [PortForward]? = nil, vmnet: Bool = false, segment: QEMUSegmentNIC? = nil
  ) {
    self.boot = boot
    self.firmware = firmware
    self.disk = disk
    self.seed = seed
    self.gdbPort = gdbPort
    self.sshHostPort = sshHostPort
    self.forwards = forwards
    self.vmnet = vmnet
    self.segment = segment
  }
}

/// A guest's NIC on a segment: QEMU binds `portSocket` and sends to the switch's `switchSocket`
/// (both unix datagram sockets; the switch learns the port from the first frame).
public struct QEMUSegmentNIC: Sendable, Hashable {
  public var portSocket: String
  public var switchSocket: String
  public var mac: String

  public init(portSocket: String, switchSocket: String, mac: String) {
    self.portSocket = portSocket
    self.switchSocket = switchSocket
    self.mac = mac
  }
}

/// Builds the `qemu-system-*` argument array for a guest (R-302; Appendix G for defaults). The
/// process always starts halted (`-S`) and daemonized: the caller connects QMP and the serial
/// socket, then sends `cont`, so the serial log starts at the first byte.
public enum QEMUCommandLine {
  /// The QEMU target name for a guest architecture (`qemu-system-<target>`, R-310): arm64 is
  /// aarch64, any other name is QEMU's own (`riscv64`, `ppc64`, `loongarch64`), or nil when it is
  /// not a plausible target name.
  public static func target(for arch: GuestSpec.Arch) -> String? {
    switch arch {
    case .arm64: return "aarch64"
    case .x86_64: return "x86_64"
    case .riscv64: return "riscv64"
    case .other(let name):
      let allowed = name.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
      }
      return allowed && !name.isEmpty && name.count <= 32 ? name : nil
    }
  }

  /// The machine type: `q35` for x86_64, `virt` for everything else.
  public static func machine(for arch: GuestSpec.Arch) -> String {
    arch == .x86_64 ? "q35" : "virt"
  }

  /// Whether vmlab knows this architecture's defaults (CPU model, UEFI firmware, display and
  /// input devices). An `other` architecture gets `-machine virt` and nothing else.
  static func hasDefaults(_ arch: GuestSpec.Arch) -> Bool {
    switch arch {
    case .arm64, .x86_64, .riscv64: true
    case .other: false
    }
  }

  static func unsupportedArch(_ arch: GuestSpec.Arch) -> VMLabError {
    VMLabError.invalidRequest(
      field: "guest.arch", reason: "\(arch.rawValue) is not a QEMU target name",
      hint: "Use arm64, x86_64, riscv64 or a qemu-system-<arch> name such as ppc64.")
  }

  /// The arguments (without the executable) for `record` under `plan`.
  public static func arguments(
    record: VMRecord, plan: Plan, layout: QEMULayout, options: QEMULaunchOptions
  ) throws(VMLabError) -> [String] {
    try layout.validate()
    let arch = plan.guest.arch
    guard target(for: arch) != nil else { throw unsupportedArch(arch) }
    let accel: String
    switch plan.profile {
    case .qemuHVF:
      guard arch == .arm64 else {
        throw VMLabError.invalidRequest(
          field: "guest.arch", reason: "qemu-hvf runs arm64 guests only",
          hint: "Ask for an arm64 guest, or let the plan choose qemu-tcg.")
      }
      accel = "hvf"
    case .qemuTCG: accel = "tcg"
    case .vzLinux, .vzMacOS:
      throw VMLabError(
        code: .internal, message: "The QEMU backend was asked to run a \(plan.profile) plan.",
        hint: "This is a vmlab bug; report it.", data: ["profile": .string(plan.profile.rawValue)])
    }
    let resources = ResourceLimits.resolve(plan.resources, for: plan.guest.os)
    var cpus = resources.cpus ?? 2
    if accel == "tcg" { cpus = min(cpus, ProfileSelector.maxTCGCPUs) }
    let memoryGB = resources.memoryGB ?? 4
    let defaults = hasDefaults(arch)

    var args: [String] = []
    args += ["-name", "vmlab-\(record.id)"]
    args += ["-nodefaults", "-no-user-config"]
    args += ["-machine", machine(for: arch), "-accel", accel]
    if defaults { args += ["-cpu", accel == "hvf" ? "host" : "max"] }
    args += ["-smp", "\(cpus)", "-m", "\(memoryGB * 1024)M"]

    args += try bootArguments(options, layout: layout)

    if options.disk {
      args += [
        "-drive",
        "if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap,file="
          + escape(layout.disk.path),
        "-device", "virtio-blk-pci,drive=disk0,bootindex=0",
      ]
    }
    if options.seed {
      args += [
        "-drive", "if=none,id=seed,format=raw,readonly=on,file=" + escape(layout.seed.path),
        "-device", "virtio-blk-pci,drive=seed",
      ]
    }

    if record.network.mode == .disabled {
      args += ["-nic", "none"]
    } else if options.vmnet {
      if !(options.forwards ?? record.network.forwards).isEmpty {
        throw VMLabError.invalidRequest(
          field: "network.forwards",
          reason: "port forwards need user-mode networking, and net_fast uses vmnet",
          hint: "Drop net_fast to forward ports, or reach the guest on its vmnet address.")
      }
      args += [
        "-netdev", "vmnet-shared,id=net0",
        "-device", "virtio-net-pci,netdev=net0,mac=\(mac(for: record.id))",
      ]
    } else {
      var netdev = "user,id=net0"
      if let ssh = options.sshHostPort { netdev += ",hostfwd=tcp:127.0.0.1:\(ssh)-:22" }
      for forward in options.forwards ?? record.network.forwards {
        guard let host = forward.host else {
          throw VMLabError(
            code: .internal,
            message: "The forward of guest port \(forward.guest) has no host port chosen.",
            hint: "This is a vmlab bug; report it.")
        }
        netdev += ",hostfwd=tcp:127.0.0.1:\(host)-:\(forward.guest)"
      }
      args += [
        "-netdev", netdev, "-device", "virtio-net-pci,netdev=net0,mac=\(mac(for: record.id))",
      ]
    }

    if let segment = options.segment, record.network.mode != .disabled {
      args += [
        "-netdev",
        "dgram,id=net1,local.type=unix,local.path=\(escape(segment.portSocket)),"
          + "remote.type=unix,remote.path=\(escape(segment.switchSocket))",
        "-device", "virtio-net-pci,netdev=net1,mac=\(segment.mac)",
      ]
    }

    // The screen VNC shows. `ramfb` rather than `virtio-gpu-pci`: edk2 exposes it as a linear GOP
    // framebuffer, which Linux's efifb/simpledrm keep driving; Debian's cloud kernel has no DRM at
    // all, so with virtio-gpu its screen went dark once the kernel took over.
    // An `other` architecture gets none of these: vmlab does not know its devices (R-310).
    if defaults {
      args += ["-device", "ramfb"]
      // Absolute pointers, so VNC clicks land where the screenshot says. USB for firmware and
      // full kernels; virtio-input for cloud kernels, which have no USB stack.
      args += ["-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet"]
      args += ["-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci"]
    }
    args += ["-qmp", "unix:\(layout.qmpSocket.path),server,wait=off"]
    args += ["-serial", "unix:\(layout.serialSocket.path),server,wait=off"]
    args += ["-vnc", "unix:\(layout.vncSocket.path)"]
    if plan.grants(.gdb) {
      guard let port = options.gdbPort else {
        throw VMLabError(
          code: .internal, message: "The plan grants gdb but no GDB port was chosen.",
          hint: "This is a vmlab bug; report it.")
      }
      args += ["-gdb", "tcp:127.0.0.1:\(port)"]
    }
    args += ["-pidfile", layout.pidFile.path, "-display", "none", "-daemonize", "-S"]
    // R-306: the request's own arguments, verbatim and last, when the plan grants them.
    if let extra = record.extra, !extra.qemuArgs.isEmpty {
      guard plan.grants(.customDevices) else {
        throw VMLabError.invalidRequest(
          field: "extra.qemuArgs", reason: "the plan does not grant custom_devices",
          hint: "Require custom_devices, or drop extra.qemuArgs.")
      }
      try extra.validate()
      args += extra.qemuArgs
    }
    return args
  }

  /// The firmware and loader arguments of each boot mode (R-305).
  static func bootArguments(
    _ options: QEMULaunchOptions, layout: QEMULayout
  ) throws(VMLabError) -> [String] {
    let boot = options.boot
    func pflash(_ code: String) -> [String] {
      [
        "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=" + escape(code),
        "-drive", "if=pflash,format=raw,unit=1,file=" + escape(layout.efiVars.path),
      ]
    }
    switch boot.mode {
    case .disk:
      guard let firmware = options.firmware else {
        throw VMLabError.invalidRequest(
          field: "boot.mode", reason: "vmlab has no UEFI firmware for this architecture",
          hint: "Boot with boot.mode kernel, firmware or binary.")
      }
      return pflash(firmware.code)
    case .firmware:
      guard let custom = boot.firmware else {
        throw VMLabError.invalidRequest(
          field: "boot.firmware", reason: "firmware boot needs a firmware image",
          hint: "Set boot.firmware, or use boot.mode disk.")
      }
      switch boot.firmwareFormat {
      case .pflash: return pflash(custom)
      case .bios: return ["-bios", custom]
      }
    case .kernel:
      guard let kernel = boot.kernel else {
        throw VMLabError.invalidRequest(
          field: "boot.kernel", reason: "kernel boot needs a kernel path",
          hint: "Set boot.kernel, or run images extract_kernel on the guest's image.")
      }
      var args = ["-kernel", kernel]
      if let initrd = boot.initrd { args += ["-initrd", initrd] }
      if let cmdline = boot.cmdline { args += ["-append", cmdline] }
      if let dtb = boot.dtb { args += ["-dtb", dtb] }
      return args
    case .binary:
      guard let binary = boot.binary, let address = boot.parsedLoadAddress else {
        throw VMLabError.invalidRequest(
          field: "boot.binary", reason: "binary boot needs a binary and a load address",
          hint: "Set boot.binary and boot.loadAddress (hex).")
      }
      // A raw image at `addr`; `cpu-num=0` points the first CPU's PC at it. No firmware runs.
      return [
        "-device",
        "loader,file=\(escape(binary)),addr=0x\(String(address, radix: 16)),cpu-num=0,"
          + "force-raw=on",
      ]
    }
  }

  /// A value inside a QEMU `key=value,...` option: commas are doubled.
  static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: ",", with: ",,")
  }

  /// A stable locally administered MAC (QEMU's `52:54:00` prefix) derived from the VM id, so a
  /// guest keeps its address across restarts and two guests on one segment differ.
  public static func mac(for id: String) -> String {
    var hash: UInt32 = 2_166_136_261
    for byte in id.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    let bytes = [UInt8(hash >> 16 & 0xff), UInt8(hash >> 8 & 0xff), UInt8(hash & 0xff)]
    return (["52", "54", "00"] + bytes.map { String(format: "%02x", $0) }).joined(separator: ":")
  }
}
