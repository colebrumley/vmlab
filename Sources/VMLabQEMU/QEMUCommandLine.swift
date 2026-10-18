import Foundation
import VMLabCore

/// What a launch needs beyond the record and the plan.
public struct QEMULaunchOptions: Sendable, Hashable {
  public var boot: BootSpec
  /// UEFI code and vars for `.disk` boot; ignored for `.kernel`.
  public var firmware: QEMUFirmware?
  /// Whether `seed.iso` is attached as a second virtio disk.
  public var seed: Bool
  /// The loopback TCP port for `-gdb` when the plan grants `gdb`.
  public var gdbPort: Int?
  /// The loopback TCP port forwarded to the guest's port 22.
  public var sshHostPort: Int?

  public init(
    boot: BootSpec = BootSpec(), firmware: QEMUFirmware? = nil, seed: Bool = false,
    gdbPort: Int? = nil, sshHostPort: Int? = nil
  ) {
    self.boot = boot
    self.firmware = firmware
    self.seed = seed
    self.gdbPort = gdbPort
    self.sshHostPort = sshHostPort
  }
}

/// Builds the `qemu-system-*` argument array for a guest (R-302; Appendix G for defaults). The
/// process always starts halted (`-S`) and daemonized: the caller connects QMP and the serial
/// socket, then sends `cont`, so the serial log starts at the first byte.
public enum QEMUCommandLine {
  /// The QEMU target name for a guest architecture, or nil when vmlab does not build one.
  public static func target(for arch: GuestSpec.Arch) -> String? {
    switch arch {
    case .arm64: "aarch64"
    case .x86_64: "x86_64"
    default: nil
    }
  }

  static func unsupportedArch(_ arch: GuestSpec.Arch) -> VMLabError {
    VMLabError.invalidRequest(
      field: "guest.arch", reason: "QEMU guests are arm64 or x86_64, not \(arch.rawValue)",
      hint: "Ask for an arm64 or x86_64 guest.")
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
    let cpus = resources.cpus ?? 2
    let memoryGB = resources.memoryGB ?? 4

    var args: [String] = []
    args += ["-name", "vmlab-\(record.id)"]
    args += ["-nodefaults", "-no-user-config"]
    args += ["-machine", arch == .arm64 ? "virt" : "q35", "-accel", accel]
    args += ["-cpu", accel == "hvf" ? "host" : "max"]
    args += ["-smp", "\(cpus)", "-m", "\(memoryGB * 1024)M"]

    switch options.boot.mode {
    case .disk, .firmware:
      let code: String
      if options.boot.mode == .firmware, let custom = options.boot.firmware {
        code = custom
      } else if let firmware = options.firmware {
        code = firmware.code
      } else {
        throw VMLabError(
          code: .internal, message: "No UEFI firmware was given for a disk boot.",
          hint: "This is a vmlab bug; report it.")
      }
      args += ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(code)"]
      args += ["-drive", "if=pflash,format=raw,unit=1,file=\(layout.efiVars.path)"]
    case .kernel:
      guard let kernel = options.boot.kernel else {
        throw VMLabError.invalidRequest(
          field: "boot.kernel", reason: "kernel boot needs a kernel path",
          hint: "Set boot.kernel, or use boot.mode disk.")
      }
      args += ["-kernel", kernel]
      if let initrd = options.boot.initrd { args += ["-initrd", initrd] }
      if let cmdline = options.boot.cmdline { args += ["-append", cmdline] }
    }

    args += [
      "-drive",
      "if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap,file=\(layout.disk.path)",
      "-device", "virtio-blk-pci,drive=disk0,bootindex=0",
    ]
    if options.seed {
      args += [
        "-drive", "if=none,id=seed,format=raw,readonly=on,file=\(layout.seed.path)",
        "-device", "virtio-blk-pci,drive=seed",
      ]
    }

    if record.network.mode == .disabled {
      args += ["-nic", "none"]
    } else {
      var netdev = "user,id=net0"
      if let ssh = options.sshHostPort { netdev += ",hostfwd=tcp:127.0.0.1:\(ssh)-:22" }
      for forward in record.network.forwards {
        guard let host = forward.host else { continue }
        netdev += ",hostfwd=tcp:127.0.0.1:\(host)-:\(forward.guest)"
      }
      args += [
        "-netdev", netdev, "-device", "virtio-net-pci,netdev=net0,mac=\(mac(for: record.id))",
      ]
    }

    // The screen VNC shows. `ramfb` rather than `virtio-gpu-pci`: edk2 exposes it as a linear GOP
    // framebuffer, which Linux's efifb/simpledrm keep driving; Debian's cloud kernel has no DRM at
    // all, so with virtio-gpu its screen went dark once the kernel took over.
    args += ["-device", "ramfb"]
    // Absolute pointers, so VNC clicks land where the screenshot says. USB for firmware and full
    // kernels; virtio-input for cloud kernels, which have no USB stack.
    args += ["-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet"]
    args += ["-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci"]
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
    return args
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
