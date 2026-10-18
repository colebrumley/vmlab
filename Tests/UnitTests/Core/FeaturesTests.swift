import Foundation
import Testing
import VMLabCore

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
      json: #"{"guest":{"os":"linux","arch":"arm64"},"boot":{"mode":"kernel"}}"#,
      field: "boot.kernel"),
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

  @Test func memberwiseInitValidates() {
    #expect(throws: VMLabError.self) {
      try Requirements(guest: GuestSpec(os: .macos, arch: .arm64), require: [.serial])
    }
  }
}
