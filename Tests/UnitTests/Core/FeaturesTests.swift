import Foundation
import Testing

@testable import VMLabCore

@Suite struct FeaturesTests {
  static func fixture(_ name: String) throws -> String {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Fixtures/features/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The catalogue matches the Appendix A table row for row.
  @Test func catalogueSnapshot() throws {
    #expect(Feature.catalogueMarkdown() == (try Self.fixture("catalogue.md")))
  }

  @Test func everyFeatureHasASummary() {
    #expect(Feature.allCases.count == 27)
    for feature in Feature.allCases {
      #expect(!feature.summary.isEmpty)
    }
  }

  static func decode(_ json: String) throws(VMLabError) -> Requirements {
    try Requirements.decode(json: Data(json.utf8))
  }

  struct Contradiction: CustomTestStringConvertible, Sendable {
    let json: String
    let field: String
    var testDescription: String { json }
  }

  static let contradictions: [Contradiction] = [
    .init(
      json: #"{"guest":{"os":"macos","arch":"arm64"},"require":["direct_kernel_boot"]}"#,
      field: "require[0]"),
    .init(
      json: #"{"guest":{"os":"macos","arch":"arm64"},"require":["custom_firmware"]}"#,
      field: "require[0]"),
    .init(
      json: #"{"guest":{"os":"macos","arch":"arm64"},"require":["gui","serial"]}"#,
      field: "require[1]"),
    .init(
      json: #"{"guest":{"os":"macos","arch":"arm64"},"prefer":["serial"]}"#,
      field: "prefer[0]"),
    .init(
      json: #"{"guest":{"os":"macos","arch":"arm64"},"boot":{"mode":"kernel","kernel":"/k"}}"#,
      field: "boot.mode"),
    .init(
      json: #"{"guest":{"os":"macos","arch":"arm64"},"require":["rosetta"]}"#,
      field: "require[0]"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"x86_64"},"require":["rosetta"]}"#,
      field: "require[0]"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"riscv64"},"prefer":["rosetta"]}"#,
      field: "prefer[0]"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"require":["net_none","net_nat"]}"#,
      field: "require[1]"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"require":["net_none","net_fast"]}"#,
      field: "require[1]"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"require":["net_port_forward","net_none"]}"#,
      field: "require[0]"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"require":["net_none","net_segment"]}"#,
      field: "require[1]"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"require":["net_none"],"#
        + #""network":{"mode":"nat"}}"#,
      field: "network.mode"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"#
        + #""network":{"mode":"none","forwards":[{"guest":22}]}}"#,
      field: "network.forwards"),
  ]

  @Test(arguments: contradictions)
  func contradictionIsRejected(_ c: Contradiction) {
    #expect {
      _ = try Self.decode(c.json)
    } throws: { error in
      guard let error = error as? VMLabError else { return false }
      return error.code == .invalidRequest && error.data["field"] == .string(c.field)
        && error.data["reason"] != nil && !error.hint.isEmpty
    }
  }

  static let malformed: [Contradiction] = [
    .init(json: #"{"require":["gui"]}"#, field: "guest"),
    .init(json: #"{"guest":{"os":"windows","arch":"x86_64"}}"#, field: "guest.os"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"require":["warp"]}"#, field: "require[0]"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"resources":{"cpus":0}}"#,
      field: "resources.cpus"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"network":{"forwards":[{"guest":70000}]}}"#,
      field: "network.forwards[0].guest"),
    .init(
      json:
        #"{"guest":{"os":"linux","arch":"arm64"},"boot":{"mode":"binary","loadAddress":"0x0"}}"#,
      field: "boot.binary"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"boot":{"mode":"binary","binary":"/b"}}"#,
      field: "boot.loadAddress"),
    .init(
      json:
        #"{"guest":{"os":"linux","arch":"arm64"},"boot":{"mode":"binary","binary":"/b","loadAddress":"0xZZ"}}"#,
      field: "boot.loadAddress"),
    .init(
      json:
        #"{"guest":{"os":"linux","arch":"arm64"},"boot":{"mode":"firmware","firmware":"/f","firmwareFormat":"rom"}}"#,
      field: "boot.firmwareFormat"),
  ]

  @Test(arguments: malformed)
  func malformedRequestIsRejected(_ c: Contradiction) {
    #expect {
      _ = try Self.decode(c.json)
    } throws: { error in
      (error as? VMLabError)?.code == .invalidRequest
        && (error as? VMLabError)?.data["field"] == .string(c.field)
    }
  }

  static let valid: [String] = [
    #"{"guest":{"os":"linux","arch":"arm64"}}"#,
    #"{"guest":{"os":"macos","arch":"arm64"},"require":["gui","exec_ssh"],"prefer":["checkpoint_live"]}"#,
    #"{"guest":{"os":"linux","arch":"arm64"},"require":["serial","gdb","checkpoint_live"],"prefer":["net_fast"],"resources":{"cpus":4,"memoryGB":8,"diskGB":32},"network":{"mode":"nat","segment":"cluster-a","forwards":[{"guest":22},{"guest":8080,"host":18080}]},"image":"debian-13-arm64","boot":{"mode":"kernel","kernel":"/k","initrd":"/i","cmdline":"console=ttyAMA0","haltAtStart":false}}"#,
    #"{"guest":{"os":"linux","arch":"arm64"},"require":["rosetta","exec_ssh"]}"#,
    #"{"guest":{"os":"linux","arch":"arm64"},"require":["net_none","exec_agent"]}"#,
    #"{"guest":{"os":"linux","arch":"x86_64"},"require":["serial","gdb","halt_at_start"]}"#,
    #"{"guest":{"os":"linux","arch":"riscv64"},"boot":{"mode":"firmware","firmware":"/fw.bin"}}"#,
    #"{"guest":{"os":"linux","arch":"loongarch64"},"require":["custom_devices"]}"#,
    #"{"guest":{"os":"macos","arch":"arm64"},"require":["net_none"],"network":{"mode":"none"}}"#,
    #"{"guest":{"os":"linux","arch":"arm64"},"require":["many_guests","net_segment"],"network":{"segment":"lab"},"provision":{"packages":["jq"]}}"#,
    #"{"guest":{"os":"linux","arch":"arm64"},"boot":{"mode":"kernel","cmdline":"console=ttyAMA0"}}"#,
    #"{"guest":{"os":"linux","arch":"x86_64"},"boot":{"mode":"firmware","firmware":"/b","firmwareFormat":"bios"}}"#,
    #"{"guest":{"os":"linux","arch":"arm64"},"boot":{"mode":"binary","binary":"/b","loadAddress":"0x40080000","dtb":"/d"}}"#,
  ]

  @Test(arguments: valid)
  func validRequestDecodes(_ json: String) throws {
    let requirements = try Self.decode(json)
    let again = try JSONDecoder().decode(
      Requirements.self, from: try JSONEncoder().encode(requirements))
    #expect(again == requirements)
  }

  @Test func decodedFieldsAndDefaults() throws {
    let r = try Self.decode(Self.valid[2])
    #expect(r.guest == GuestSpec(os: .linux, arch: .arm64))
    #expect(r.require == [.serial, .gdb, .checkpointLive])
    #expect(r.prefer == [.netFast])
    #expect(r.resources == ResourceSpec(cpus: 4, memoryGB: 8, diskGB: 32))
    #expect(r.network.forwards == [PortForward(guest: 22), PortForward(guest: 8080, host: 18080)])
    #expect(r.boot?.mode == .kernel)
    let bare = try Self.decode(Self.valid[0])
    #expect(bare.require.isEmpty && bare.prefer.isEmpty && bare.image == nil && bare.boot == nil)
    #expect(bare.network == NetworkSpec())
    #expect(try Self.decode(Self.valid[7]).guest.arch == .other("loongarch64"))
  }

  @Test func bootImpliesItsFeatures() throws {
    let binary = try Self.decode(
      #"{"guest":{"os":"linux","arch":"arm64"},"boot":{"mode":"binary","binary":"/b","loadAddress":"0x1000"}}"#
    )
    #expect(binary.boot?.parsedLoadAddress == 0x1000)
    #expect(binary.boot?.firmwareFormat == .pflash)
    #expect(BootSpec(loadAddress: "4096").parsedLoadAddress == 4096)
    let mac =
      #"{"guest":{"os":"macos","arch":"arm64"},"boot":{"mode":"binary","binary":"/b","loadAddress":"0x1000"}}"#
    #expect(throws: VMLabError.self) { try Self.decode(mac) }
  }

  /// R-306: extra.qemuArgs decodes, implies custom_devices, and the denylist is invalid_request.
  @Test func qemuArgsPassThroughAndDenylist() throws {
    let ok = try Self.decode(
      #"{"guest":{"os":"linux","arch":"arm64"},"extra":{"qemuArgs":["-device","virtio-rng-pci"]}}"#)
    #expect(ok.extra?.qemuArgs == ["-device", "virtio-rng-pci"])
    #expect(ok.impliedFeatures.map(\.feature) == [.customDevices])
    let empty = try Self.decode(#"{"guest":{"os":"linux","arch":"arm64"},"extra":{}}"#)
    #expect(empty.extra?.qemuArgs == [] && empty.impliedFeatures.isEmpty)
    for denied in [
      "-qmp", "-serial", "-vnc", "-gdb", "-pidfile", "-daemonize", "-monitor", "--monitor",
      "-gdb=tcp::1", "-s", "-mon", "-qmp-pretty", "-readconfig", "-plugin", "--run-with",
    ] {
      let json =
        #"{"guest":{"os":"linux","arch":"arm64"},"extra":{"qemuArgs":["-device","x",""#
        + denied + #"","y"]}}"#
      #expect {
        _ = try Self.decode(json)
      } throws: { error in
        guard let error = error as? VMLabError else { return false }
        return error.code == .invalidRequest && error.data["field"] == .string("extra.qemuArgs[2]")
      }
    }
    // A value that merely looks like a denied name is an argument, not an option.
    #expect(ExtraSpec.optionName("serial") == nil)
    #expect(ExtraSpec.optionName("--gdb=tcp::1") == "gdb")
    let mac = #"{"guest":{"os":"macos","arch":"arm64"},"extra":{"qemuArgs":["-device","x"]}}"#
    #expect(throws: Never.self) { _ = try Self.decode(mac) }
  }

  /// BH-1: `-incoming exec:<cmd>` makes QEMU run `/bin/sh -c <cmd>` on the host at startup
  /// (checked by hand with QEMU 11.1.2), and an HMP monitor on a chardev (`mon:` prefix) can
  /// `migrate exec:` too. The surface is an allowlist; these and their relatives are refused.
  @Test func qemuArgsRefuseHostCommandsAndMonitors() {
    for args in [
      ["-incoming", "exec:touch /tmp/pwned"],
      ["--incoming=exec:touch /tmp/pwned"],
      ["-parallel", "mon:unix:/tmp/m.sock,server=on,wait=off"],
      ["-debugcon", "mon:stdio"],
      ["-chardev", "socket,id=c,path=/tmp/m.sock,server=on,mux=on", "-device", "x,chardev=mon:c"],
      ["-netdev", "user,id=n,guestfwd=tcp:10.0.2.100:80-cmd:/bin/sh"],
      ["-netdev", "user,id=n,smb=/tmp"],
      ["-netdev", "tap,id=n,script=/tmp/up.sh"],
      ["-chardev", "stdio,id=c"],
      ["-chardev", "serial,id=c,path=/dev/cu.usbserial"],
      ["-chardev", "socket,id=c,fd=3"],
      ["-set", "device.x.romfile=/etc/passwd"],
      ["-add-fd", "fd=3,set=1"], ["-sandbox", "off"], ["-trace", "file=/tmp/t"],
      ["-D", "/tmp/log"], ["-L", "/tmp"], ["-bios", "/tmp/b"], ["-kernel", "/tmp/k"],
      ["-pflash", "/tmp/p"], ["-virtfs", "local,path=/,mount_tag=t"], ["-fsdev", "local,id=f"],
      ["-plugin", "/tmp/p.dylib"], ["-semihosting"], ["-machine", "virt"],
      ["-object", #"{"qom-type":"memory-backend-file","id":"m","mem-path":"/etc"}"#],
      ["-drive", "file=json:{\"file.filename\":\"/etc/passwd\"}"],
      ["-drive", "file=relative.qcow2"],
      ["-device", "usb-host,vendorid=1"],
      ["-device"], ["virtio-rng-pci"], ["-device", "virtio-rng-pci", "stray"],
      ["-device=virtio-rng-pci"],
    ] {
      #expect(throws: VMLabError.self, "\(args)") { try ExtraSpec(qemuArgs: args).validate() }
    }
    for args in [
      ["-device", "virtio-rng-pci"], ["-global", "a.b=c,,d"], ["-usb", "-no-reboot"],
      ["-drive", "if=none,id=d1,file=/tmp/extra.qcow2", "-device", "virtio-blk-pci,drive=d1"],
      ["-object", "rng-random,id=r,filename=/dev/urandom", "-device", "virtio-rng-pci,rng=r"],
      ["-chardev", "socket,id=c,path=/tmp/vmlab-x.sock,server=on,wait=off"],
      ["-netdev", "user,id=n2,hostfwd=tcp:127.0.0.1:8080-:80", "-device", "e1000,netdev=n2"],
    ] {
      #expect(throws: Never.self, "\(args)") { try ExtraSpec(qemuArgs: args).validate() }
    }
  }

  /// BH-1: host paths in qemuArgs follow the R-1102 path policy, stay out of vmlab's home (its
  /// QMP sockets and disks) and are not existing unix sockets; `,,` does not hide a key.
  @Test func qemuArgsHostPathsFollowThePathPolicy() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "vmlab-qa-\(UUID())")
    let vmlabHome = root.appending(path: "vmlab")
    try FileManager.default.createDirectory(at: vmlabHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let policy = PathPolicy(roots: [root.path])
    func check(_ args: [String]) throws {
      let spec = ExtraSpec(qemuArgs: args)
      try spec.validate()
      try spec.checkHostPaths(policy: policy, vmlabHome: vmlabHome)
    }
    #expect(ExtraSpec.parseOptions("a=b,,c,d").map(\.value) == ["b,c", "d"])
    try check(["-drive", "if=none,id=d,file=\(root.path)/x.qcow2"])
    try check(["-object", "rng-random,id=r,filename=/dev/urandom"])
    for args in [
      ["-drive", "if=none,id=d,file=/etc/passwd"],
      ["-blockdev", "driver=raw,node-name=n,file.driver=file,file.filename=/etc/passwd"],
      ["-device", "loader,file=/etc/passwd,addr=0x1000"],
      ["-global", "driver=virtio-net-pci,property=romfile,value=/etc/passwd"],
      ["-global", "virtio-net-pci.romfile=/etc/passwd"],
      ["-object", "memory-backend-file,id=m,size=1M,mem-path=/var/tmp"],
      ["-drive", "if=none,id=d,file=\(vmlabHome.path)/vms/other/disk.qcow2"],
      ["-chardev", "socket,id=c,path=\(vmlabHome.path)/vms/other/qmp.sock"],
    ] {
      #expect(throws: VMLabError.self, "\(args)") { try check(args) }
    }
    // An existing unix socket (an agent the guest could drive) is refused.
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
    let open = PathPolicy(roots: ["/tmp", root.path])
    #expect(throws: VMLabError.self) {
      let spec = ExtraSpec(qemuArgs: ["-chardev", "socket,id=c,path=\(socketPath)"])
      try spec.checkHostPaths(policy: open, vmlabHome: vmlabHome)
    }
  }

  @Test func memberwiseInitValidates() {
    #expect(throws: VMLabError.self) {
      try Requirements(guest: GuestSpec(os: .macos, arch: .arm64), require: [.serial])
    }
  }

  /// R-404: `share` decodes, implies shared_dir, refuses relative or fstab-breaking paths, and a
  /// record mounts a share only when the request asked for one.
  @Test func shareImpliesSharedDirAndValidates() throws {
    let ok = try Self.decode(
      #"{"guest":{"os":"linux","arch":"arm64"},"share":{"host":"/tmp/x","guest":"/srv/x"}}"#)
    #expect(ok.share == SharedDirSpec(host: "/tmp/x", guest: "/srv/x"))
    #expect(ok.impliedFeatures.map(\.feature) == [.sharedDir])
    #expect(
      try Self.decode(#"{"guest":{"os":"linux","arch":"arm64"},"share":{}}"#).share?
        .guestPath == "/mnt/host")
    for (share, field) in [
      (#"{"host":"relative"}"#, "share.host"), (#"{"guest":"mnt"}"#, "share.guest"),
      (#"{"guest":"/mnt/a b"}"#, "share.guest"), (#"{"guest":"/"}"#, "share.guest"),
    ] {
      let error = #expect(throws: VMLabError.self) {
        try Self.decode(#"{"guest":{"os":"linux","arch":"arm64"},"share":"# + share + "}")
      }
      #expect(error?.data["field"] == .string(field), "\(share)")
    }

    let guest = GuestSpec(os: .linux, arch: .arm64)
    var record = VMRecord(id: "vm-aaaaaa", profile: .qemuHVF, guest: guest, features: [.sharedDir])
    #expect(SharedDirSpec.of(record) == nil, "granted but not asked for: nothing mounted")
    record.plan = Plan(
      profile: .qemuHVF, guest: guest, resources: ResourceSpec(), features: [.sharedDir],
      requested: [.sharedDir], estimatedStartupSeconds: 1)
    #expect(SharedDirSpec.of(record) == SharedDirSpec())
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-share-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    try SharedDirSpec().checkHostDirectory(vmDirectory: dir)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "shared").path))
    record.share = SharedDirSpec(host: "/no/such/dir")
    #expect(throws: VMLabError.self) {
      try SharedDirSpec.of(record)?.checkHostDirectory(vmDirectory: dir)
    }
  }
}
