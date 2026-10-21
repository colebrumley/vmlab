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
    #expect(Feature.allCases.count == 28)
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
    // CR-2: sizes past the caps of Appendix G.
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"resources":{"diskGB":9223372036854775807}}"#,
      field: "resources.diskGB"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"resources":{"diskGB":65537}}"#,
      field: "resources.diskGB"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"resources":{"memoryGB":4097}}"#,
      field: "resources.memoryGB"),
    .init(
      json: #"{"guest":{"os":"linux","arch":"arm64"},"resources":{"cpus":257}}"#,
      field: "resources.cpus"),
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
      "-gdb=tcp::1", "-s", "-mon", "-qmp-pretty", "-readconfig", "-set", "--run-with",
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
