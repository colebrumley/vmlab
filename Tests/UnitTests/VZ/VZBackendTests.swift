import Foundation
import Testing
import VMLabCore

@testable import VMLabVZ

@Suite struct VZBackendTests {
  static let tools =
    FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")
    && FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")

  /// create clones the raw disk, makes the VM's key and a seed for the image's user with the
  /// console on hvc0 and the NAT NIC identified to DHCP by its stable MAC.
  @Test(.enabled(if: tools)) func createWritesDiskKeyAndSeed() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzb-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let images = ImageStore(home: home)
    let imageDir = images.imageDirectory("debian-13-arm64")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
    try Data("raw disk".utf8).write(to: imageDir.appending(path: "disk.raw"))
    let pulled = PulledImage(
      name: "debian-13-arm64", guest: GuestSpec(os: .linux, arch: .arm64), source: "fixture",
      format: .raw, checksum: nil, files: ["raw": "disk.raw"], login: ImageLogin(user: "debian"),
      pulledAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(pulled).write(to: imageDir.appending(path: "image.json"))

    let store = Store(home: home)
    let record = try store.create(
      VMRecord(
        id: "", name: "Dev.Box_1", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [.execSSH], image: "debian-13-arm64"))
    let backend = VZBackend(store: store)
    let plan = Plan(
      profile: .vzLinux, guest: record.guest, resources: ResourceSpec(), features: [.execSSH],
      estimatedStartupSeconds: 30)
    try await backend.create(record, plan: plan)

    let dir = store.directory(of: record.id)
    #expect(try Data(contentsOf: dir.appending(path: "disk.raw")) == Data("raw disk".utf8))
    let publicKey = try String(
      contentsOf: dir.appending(path: "id_ed25519.pub"), encoding: .utf8)
    #expect(publicKey.hasPrefix("ssh-ed25519 "))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "seed.iso").path))
    let userData = try String(contentsOf: dir.appending(path: "seed/user-data"), encoding: .utf8)
    #expect(userData.contains(publicKey.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(userData.contains("serial-getty@hvc0.service"))
    #expect(userData.contains("name: \"debian\""))
    #expect(userData.contains("\"dev-box-1\""))
    let network = try String(
      contentsOf: dir.appending(path: "seed/network-config"), encoding: .utf8)
    #expect(network.contains(VZRunnerConfig.stableMAC(for: record.id)))
    #expect(network.contains("dhcp-identifier"))

    // A second create keeps the key.
    try await backend.create(record, plan: plan)
    #expect(
      try String(contentsOf: dir.appending(path: "id_ed25519.pub"), encoding: .utf8) == publicKey)
  }

  /// R-603: a share whose host directory is missing is refused before anything is built.
  @Test func missingShareDirectoryIsInvalidRequest() {
    #expect(throws: Never.self) {
      try VZBackend.checkShares([ShareSpec(host: FileManager.default.temporaryDirectory.path)])
    }
    #expect {
      try VZBackend.checkShares([ShareSpec(host: "/tmp"), ShareSpec(host: "/no/such/dir")])
    } throws: { error in
      (error as? VMLabError)?.code == .invalidRequest
        && (error as? VMLabError)?.data["field"] == .string("shares[1].host")
    }
  }

  /// Rosetta is shared only when the request asked for it, not whenever the profile grants it.
  @Test func rosettaOnlyWhenRequested() {
    var record = VMRecord(
      id: "vm-abc234", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [.execSSH, .rosetta])
    #expect(!VZRunnerConfig.wantsRosetta(record))
    record.plan = Plan(
      profile: .vzLinux, guest: record.guest, resources: ResourceSpec(),
      features: record.features, requested: [.rosetta], estimatedStartupSeconds: 30)
    #expect(VZRunnerConfig.wantsRosetta(record))
  }

  @Test func hostnameIsADNSLabel() {
    func record(_ name: String) -> VMRecord {
      VMRecord(
        id: "vm-abc234", name: name, profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [])
    }
    #expect(VZBackend.hostname(for: record("Web Server.01")) == "web-server-01")
    #expect(VZBackend.hostname(for: record("---")) == "vm-abc234")
    #expect(VZBackend.hostname(for: record(String(repeating: "a", count: 80))).count == 63)
  }
}
