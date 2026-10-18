import Foundation
import Testing

@testable import VMLabCore

@Suite struct ExtraSpecTests {
  /// A temporary root with a VMLAB_HOME inside; the policy allows the root only.
  struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "vmlab-qa-\(UUID())")
    var vmlabHome: URL { root.appending(path: "vmlab") }
    var policy: PathPolicy { PathPolicy(roots: [root.path]) }

    init() throws {
      try FileManager.default.createDirectory(at: vmlabHome, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func check(_ args: [String], allowHostCode: Bool = false) throws {
      let spec = ExtraSpec(qemuArgs: args)
      try spec.validate()
      try spec.checkHostPaths(policy: policy, vmlabHome: vmlabHome, allowHostCode: allowHostCode)
    }
  }

  /// Options that cannot run host code, open a host monitor or descriptor, reach a host path
  /// outside the policy or pass host hardware through: accepted (`R` is the sandbox root).
  static let accepted: [[String]] = [
    ["-device", "virtio-rng-pci"], ["-global", "a.b=c,,d"], ["-usb", "-no-reboot"],
    ["-no-shutdown"],
    ["-drive", "if=none,id=d1,file=R/extra.qcow2", "-device", "virtio-blk-pci,drive=d1"],
    ["-object", "rng-random,id=r,filename=/dev/urandom", "-device", "virtio-rng-pci,rng=r"],
    ["-chardev", "socket,id=c,path=R/new.sock,server=on,wait=off"],
    ["-netdev", "user,id=n2,hostfwd=tcp:127.0.0.1:8080-:80", "-device", "e1000,netdev=n2"],
    // CPU models and features (the profile's constraint is QEMUCommandLine's).
    ["-cpu", "max,sve=on,sve256=on"], ["-cpu", "host,pmu=off"],
    ["-cpu", "Skylake-Client,+avx2,-hle"], ["-cpu", "cortex-a72"],
    // -machine properties and boards (merged into vmlab's -machine).
    ["-machine", "highmem=off"], ["-M", "virt,gic-version=3"], ["-machine", "type=sbsa-ref"],
    ["-machine", "dumpdtb=R/virt.dtb"],
    ["-icount", "shift=auto,sleep=off"], ["-icount", "7"],
    ["-icount", "shift=7,rr=record,rrfile=R/replay.bin"],
    ["-d", "int,guest_errors,trace:virtio_*"], ["-dfilter", "0x8000..0x9000"],
    ["-D", "R/qemu.log"],
    ["-trace", "virtio_*"], ["-trace", "enable=qcow2_*,file=R/trace.log"],
    ["-trace", "events=R/events.txt"],
    ["-numa", "node,nodeid=0,cpus=0-1"], ["-numa", "dist,src=0,dst=1,val=20"],
    ["-overcommit", "mem-lock=off,cpu-pm=on"], ["-mem-prealloc"], ["-mem-path", "R/hugepages"],
    // Extra serial ports: a chardev and a UART device on it.
    [
      "-chardev", "socket,id=s1,path=R/s1.sock,server=on,wait=off", "-device",
      "pci-serial,chardev=s1",
    ],
    ["-chardev", "file,id=s2,path=R/s2.log", "-device", "isa-serial,chardev=s2"],
    ["-chardev", "ringbuf,id=s3", "-device", "virtconsole,chardev=s3"],
    ["-cdrom", "R/install.iso"], ["-hda", "R/a.img"], ["-sd", "R/card.img"],
    ["-option-rom", "R/opt.rom"], ["-option-rom", "romfile=R/opt.rom,bootindex=1"],
    ["-acpitable", "sig=SSDT,file=R/a.aml:R/b.aml"],
    ["-audiodev", "none,id=a0"], ["-audiodev", "wav,id=a1,path=R/out.wav"],
    ["-audio", "none,model=hda"],
    [
      "-chardev", "socket,id=tpm,path=R/swtpm.sock,server=on,wait=off", "-tpmdev",
      "emulator,id=t0,chardev=tpm",
    ],
    ["-vga", "std"], ["-usbdevice", "tablet"],
    ["-virtfs", "local,path=R/share,mount_tag=extra,security_model=mapped-xattr"],
    ["-fsdev", "local,id=f1,path=R/share,security_model=none"],
    ["-iscsi", "initiator-name=iqn.2026-10.vmlab:guest"],
    ["-msg", "timestamp=on"], ["-compat", "deprecated-input=reject"],
    ["-uuid", "8f6c1a3e-5d2b-4c1e-9a7f-1b2c3d4e5f60"], ["-k", "en-us"], ["-seed", "42"],
    ["-watchdog-action", "pause"], ["-rtc", "base=utc,clock=vm"], ["-boot", "menu=on"],
    ["-smbios", "type=1,serial=abc"], ["-fw_cfg", "name=opt/x,string=y"],
    ["-action", "panic=pause"], ["-net", "nic,model=e1000"], ["-nic", "user,model=e1000"],
    ["-enable-sync-profile", "-only-migratable"], ["-no-fd-bootchk", "-win2k-hack"],
  ]

  /// Refused whatever the config says: host commands, monitors, descriptors, vmlab's own
  /// options, malformed arguments and host paths outside the policy.
  static let refused: [[String]] = [
    ["-incoming", "exec:touch /tmp/pwned"], ["--incoming=exec:touch /tmp/pwned"],
    ["-incoming", "defer"],
    ["-parallel", "mon:unix:/tmp/m.sock,server=on,wait=off"], ["-debugcon", "mon:stdio"],
    ["-chardev", "socket,id=c,path=R/m.sock,server=on,mux=on", "-device", "x,chardev=mon:c"],
    ["-netdev", "user,id=n,guestfwd=tcp:10.0.2.100:80-cmd:/bin/sh"],
    ["-netdev", "user,id=n,smb=/tmp"], ["-netdev", "tap,id=n,script=/tmp/up.sh"],
    ["-netdev", "tap,id=n"], ["-netdev", "bridge,id=n"], ["-netdev", "vmnet-shared,id=n"],
    ["-nic", "vmnet-host"], ["-net", "tap"],
    ["-chardev", "stdio,id=c"], ["-chardev", "socket,id=c,fd=3"],
    ["-device", "virtio-rng-pci,driver=usb-host"], ["-netdev", "user,id=n,type=tap"],
    ["-machine", "virt,type=raspi3b"],
    ["-netdev", "stream,id=n,server=off,addr.type=fd,addr.str=5"],
    ["-chardev", "socket,id=c,addr.type=fd,addr.str=4"],
    ["-set", "device.x.romfile=/etc/passwd"], ["-readconfig", "R/q.cfg"],
    ["-add-fd", "fd=3,set=1"], ["-sandbox", "off"],
    ["-monitor", "stdio"], ["-mon", "chardev=c"], ["-qmp", "unix:R/q.sock,server"],
    ["-serial", "chardev:s1"], ["-vnc", ":1"], ["-display", "cocoa"], ["-nographic"],
    ["-gdb", "tcp::1234"], ["-s"], ["-pidfile", "R/p"], ["-daemonize"], ["-S"],
    ["-name", "x"], ["-run-with", "user=nobody"], ["-smp", "8"], ["-m", "8G"],
    ["-accel", "tcg"], ["-L", "/tmp"], ["-bios", "/tmp/b"], ["-kernel", "/tmp/k"],
    ["-pflash", "/tmp/p"], ["-snapshot"], ["-loadvm", "x"],
    ["-machine", "accel=tcg"], ["-machine", "virt,kernel=R/k"], ["-M", "dtb=R/x.dtb"],
    ["-cpu", "+sve"], ["-cpu", "max", "-cpu", "host"], ["-cpu", "max,bare"],
    ["-object", #"{"qom-type":"memory-backend-file","id":"m","mem-path":"/etc"}"#],
    ["-object", "dbus-vmstate,id=d,addr=unix:path=/tmp/b"],
    ["-drive", "file=json:{\"file.filename\":\"/etc/passwd\"}"],
    ["-drive", "file=relative.qcow2"], ["-D", "relative.log"], ["-cdrom", "x.iso"],
    ["-device"], ["virtio-rng-pci"], ["-device", "virtio-rng-pci", "stray"],
    ["-device=virtio-rng-pci"], ["-no-such-option"], ["-h"],
    ["-drive", "if=none,id=d,file=/etc/passwd"],
    ["-blockdev", "driver=raw,node-name=n,file.driver=file,file.filename=/etc/passwd"],
    ["-device", "loader,file=/etc/passwd,addr=0x1000"],
    ["-global", "driver=virtio-net-pci,property=romfile,value=/etc/passwd"],
    ["-global", "virtio-net-pci.romfile=/etc/passwd"],
    ["-object", "memory-backend-file,id=m,size=1M,mem-path=/var/tmp"],
    ["-D", "/etc/qemu.log"], ["-D", "V/qemu.log"], ["-mem-path", "/var/tmp"],
    ["-trace", "file=/etc/trace"], ["-trace", "events=/etc/passwd"],
    ["-icount", "rr=replay,rrfile=/etc/passwd"], ["-machine", "dumpdtb=/etc/x.dtb"],
    ["-acpitable", "file=R/a.aml:/etc/passwd"], ["-cdrom", "/etc/passwd"],
    ["-virtfs", "local,path=/,mount_tag=t,security_model=none"],
    ["-fsdev", "proxy,id=f,socket=/tmp/p"], ["-audiodev", "pa,id=a"], ["-audio", "model=hda"],
    ["-drive", "if=none,id=d,file=V/vms/other/disk.qcow2"],
    ["-chardev", "socket,id=c,path=V/vms/other/qmp.sock"],
  ]

  /// Accepted only with the owner's `allowHostCode`.
  static let hostCode: [[String]] = [
    ["-plugin", "R/libinsn.dylib,inline=on"], ["-plugin", "file=R/libmem.dylib"],
    ["-semihosting"], ["-semihosting-config", "enable=on,target=native"],
    ["-device", "usb-host,vendorid=0x1234"], ["-device", "vfio-pci,host=01:00.0"],
    ["-device", "u2f-passthru"], ["-device", "vhost-user-fs-pci,chardev=c,tag=t"],
    ["-device", "vhost-vsock-pci,guest-cid=3"],
    ["-chardev", "serial,id=c,path=R/cu.usbserial"], ["-chardev", "tty,id=c,path=R/tty"],
    ["-netdev", "vhost-user,id=n,chardev=c"], ["-tpmdev", "passthrough,id=t,path=R/tpm0"],
    ["-audiodev", "coreaudio,id=a"], ["-object", "input-linux,id=i,evdev=R/event0"],
  ]

  static func substitute(_ args: [String], _ sandbox: Sandbox) -> [String] {
    args.map {
      $0.replacingOccurrences(of: "=R/", with: "=\(sandbox.root.path)/")
        .replacingOccurrences(of: ":R/", with: ":\(sandbox.root.path)/")
        .replacingOccurrences(of: "=V/", with: "=\(sandbox.vmlabHome.path)/")
        .replacingOccurrences(of: "unix:R/", with: "unix:\(sandbox.root.path)/")
        .replacingOccurrences(of: "R/", with: "\(sandbox.root.path)/", options: .anchored)
        .replacingOccurrences(of: "V/", with: "\(sandbox.vmlabHome.path)/", options: .anchored)
    }
  }

  @Test func acceptsWhatCannotReachTheHost() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    for args in Self.accepted.map({ Self.substitute($0, sandbox) }) {
      #expect(throws: Never.self, "\(args)") { try sandbox.check(args) }
    }
  }

  @Test func refusesWhatReachesTheHost() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    for args in Self.refused.map({ Self.substitute($0, sandbox) }) {
      #expect("\(args)") {
        try sandbox.check(args, allowHostCode: true)
      } throws: { error in
        guard let error = error as? VMLabError else { return false }
        return error.code == .invalidRequest
          && error.data["field"]?.stringValue?.hasPrefix("extra.qemuArgs[") == true
      }
    }
  }

  /// Host code is refused by default, with the config key in the hint, and accepted with
  /// `allowHostCode`, its host paths still held to the policy.
  @Test func hostCodeNeedsTheOwnersOptIn() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    for args in Self.hostCode.map({ Self.substitute($0, sandbox) }) {
      try ExtraSpec(qemuArgs: args).validate()
      #expect("\(args)") {
        try sandbox.check(args)
      } throws: { error in
        guard let error = error as? VMLabError else { return false }
        return error.code == .invalidRequest && error.hint.contains("\"allowHostCode\": true")
      }
      #expect(throws: Never.self, "\(args)") { try sandbox.check(args, allowHostCode: true) }
    }
    #expect(throws: VMLabError.self) {
      try sandbox.check(["-plugin", "/etc/libx.dylib"], allowHostCode: true)
    }
    #expect(throws: VMLabError.self) {
      try sandbox.check(["-chardev", "serial,id=c,path=/dev/cu.usbserial"], allowHostCode: true)
    }
  }

  /// The owner's toggle lives in VMLAB_HOME/config.json and defaults off.
  @Test func allowHostCodeIsReadFromTheConfig() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    #expect(!VMLabConfig.load(home: sandbox.vmlabHome).allowHostCode)
    try Data(#"{"allowHostCode": true}"#.utf8).write(to: VMLabConfig.url(home: sandbox.vmlabHome))
    #expect(VMLabConfig.load(home: sandbox.vmlabHome).allowHostCode)
    #expect(!VMLabConfig.load(home: sandbox.vmlabHome).allowAnyPath)
  }

  /// Refusals name the option and why.
  @Test func refusalsSayWhy() {
    func reason(_ args: [String]) -> String? {
      do {
        try ExtraSpec(qemuArgs: args).validate()
        return nil
      } catch { return error.message + " " + error.hint }
    }
    #expect(reason(["-serial", "pty"])?.contains("pci-serial") == true)
    #expect(reason(["-incoming", "defer"])?.contains("-incoming") == true)
    #expect(reason(["-machine", "accel=tcg"])?.contains("accel") == true)
    #expect(reason(["-smp", "4"])?.contains("resources.cpus") == true)
  }

  /// `-cpu` and `-machine` are split out for vmlab's own options; the rest are appended.
  @Test func cpuAndMachineAreSplitOut() throws {
    let spec = ExtraSpec(qemuArgs: [
      "-machine", "virt,highmem=off", "-device", "virtio-rng-pci", "-cpu", "max,sve=on", "-M",
      "dumpdtb=/tmp/a,,b.dtb", "-usb",
    ])
    try spec.validate()
    #expect(spec.cpu?.value == "max,sve=on" && spec.cpu?.index == 5)
    #expect(spec.machineType?.value == "virt")
    #expect(spec.machineProperties == ["highmem=off", "dumpdtb=/tmp/a,,b.dtb"])
    #expect(spec.appendedArguments == ["-device", "virtio-rng-pci", "-usb"])
    #expect(!spec.usesICount)
    #expect(ExtraSpec.parseOptions("a=b,,c,d").map(\.value) == ["b,c", "d"])
  }

  /// BH-1: an existing unix socket (an agent the guest could drive) is refused.
  @Test func existingUnixSocketsAreRefused() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let socketPath = "/tmp/vmlab-qa-\(getpid()).sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer {
      close(fd)
      unlink(socketPath)
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
      for (offset, byte) in socketPath.utf8.enumerated() { buffer[offset] = byte }
    }
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(bound == 0)
    let open = PathPolicy(roots: ["/tmp", sandbox.root.path])
    #expect(throws: VMLabError.self) {
      let spec = ExtraSpec(qemuArgs: ["-chardev", "socket,id=c,path=\(socketPath)"])
      try spec.checkHostPaths(policy: open, vmlabHome: sandbox.vmlabHome, allowHostCode: true)
    }
  }
}
