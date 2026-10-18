import Foundation
import Testing
import VMLabCore

@Suite struct DHCPLeasesTests {
  static let fixture = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/vz/dhcpd_leases")
  /// Before the fixture's newest leases expire, after the 2020 one did.
  static let now = Date(timeIntervalSince1970: 1_791_800_000)

  static func text() throws -> String { try String(contentsOf: fixture, encoding: .utf8) }

  @Test func parsesBlocksAndNormalisesMACs() throws {
    let leases = DHCPLeases.parse(try Self.text())
    // The block without an ip_address is skipped; the DUID-keyed one is not a MAC.
    #expect(leases.map(\.ipAddress) == ["192.168.64.7", "192.168.64.9", "192.168.64.3"])
    #expect(leases[0].hardwareAddress == "02:0a:3b:4c:5d:6e")
    #expect(leases[0].name == "debian")
    #expect(leases[0].expires == Date(timeIntervalSince1970: 0x6acd_059d))
  }

  /// macOS writes `2:a:3b:…`; the VM's MAC is `02:0A:3B:…`. The newest unexpired lease wins.
  @Test(arguments: ["02:0a:3b:4c:5d:6e", "02:0A:3B:4C:5D:6E", "2:a:3b:4c:5d:6e"])
  func findsNewestLeaseByMAC(mac: String) throws {
    #expect(DHCPLeases.ip(for: mac, in: try Self.text(), now: Self.now) == "192.168.64.9")
  }

  @Test func expiredUnknownAndMalformedMACsHaveNoAddress() throws {
    let text = try Self.text()
    #expect(DHCPLeases.ip(for: "52:54:00:0a:0c:01", in: text, now: Self.now) == nil)
    #expect(DHCPLeases.ip(for: "02:00:00:00:00:99", in: text, now: Self.now) == nil)
    #expect(DHCPLeases.ip(for: "not-a-mac", in: text, now: Self.now) == nil)
    #expect(DHCPLeases.lookup(mac: "02:0a:3b:4c:5d:6e", path: "/nonexistent/leases") == nil)
  }

  @Test func macNormalisation() {
    #expect(DHCPLeases.normalizeMAC("2:A:3b:4c:5d:6e") == "02:0a:3b:4c:5d:6e")
    #expect(DHCPLeases.normalizeMAC("02:0a:3b:4c:5d") == nil)
    #expect(DHCPLeases.normalizeMAC("02:0a:3b:4c:5d:6e:7f") == nil)
    #expect(DHCPLeases.normalizeMAC("002:0a:3b:4c:5d:6e") == nil)
    #expect(DHCPLeases.normalizeMAC("zz:0a:3b:4c:5d:6e") == nil)
    #expect(DHCPLeases.normalizeMAC("02::3b:4c:5d:6e") == nil)
  }

  @Test func waitReturnsOnceTheLeaseAppears() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "leases-\(UUID())")
    defer { try? FileManager.default.removeItem(at: file) }
    let mac = "02:0a:3b:4c:5d:6e"
    #expect(
      await DHCPLeases.waitForIP(mac: mac, path: file.path, timeout: .milliseconds(200)) == nil)
    let future = String(UInt64(Date().timeIntervalSince1970) + 3600, radix: 16)
    try "{\n\tip_address=192.168.64.20\n\thw_address=1,2:a:3b:4c:5d:6e\n\tlease=0x\(future)\n}\n"
      .write(to: file, atomically: true, encoding: .utf8)
    #expect(
      await DHCPLeases.waitForIP(mac: mac, path: file.path, timeout: .seconds(2))
        == "192.168.64.20")
  }
}
