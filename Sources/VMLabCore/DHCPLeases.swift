import Foundation

/// One entry of macOS's vmnet DHCP server lease file.
public struct DHCPLease: Sendable, Hashable {
  public var name: String?
  public var ipAddress: String
  /// Normalised (`DHCPLeases.normalizeMAC`).
  public var hardwareAddress: String
  /// When the lease expires (the file's `lease=0x…`, seconds since 1970).
  public var expires: Date?
}

/// Reads `/var/db/dhcpd_leases`, which `bootpd` writes for the NAT network
/// (`VZNATNetworkDeviceAttachment`). The file is world-readable, so no root is needed (C2).
public enum DHCPLeases {
  public static let defaultPath = "/var/db/dhcpd_leases"

  /// Lowercase, two digits per octet: `2:A:3b:4c:5d:6e` → `02:0a:3b:4c:5d:6e`. macOS's
  /// `dhcpd_leases` drops leading zeros; nil unless there are six hex octets of one or two digits.
  public static func normalizeMAC(_ text: String) -> String? {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6 else { return nil }
    var octets: [String] = []
    for part in parts {
      guard (1...2).contains(part.count), let value = UInt8(part, radix: 16) else { return nil }
      octets.append(String(format: "%02x", value))
    }
    return octets.joined(separator: ":")
  }

  /// Every well-formed `{ … }` block of `text`; blocks without an address or MAC are skipped.
  public static func parse(_ text: String) -> [DHCPLease] {
    var leases: [DHCPLease] = []
    var fields: [String: String]? = nil
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line == "{" {
        fields = [:]
      } else if line == "}" {
        if let fields, let lease = lease(fields) { leases.append(lease) }
        fields = nil
      } else if fields != nil, let eq = line.firstIndex(of: "=") {
        fields?[String(line[..<eq])] = String(line[line.index(after: eq)...])
      }
    }
    return leases
  }

  static func lease(_ fields: [String: String]) -> DHCPLease? {
    guard let ip = fields["ip_address"], let hw = fields["hw_address"] else { return nil }
    // `hw_address=1,2:a:3b:4c:5d:6e`: the hardware type (1, Ethernet), then the MAC.
    let mac = hw.split(separator: ",", maxSplits: 1).last.map(String.init) ?? hw
    guard let normalized = DHCPLeases.normalizeMAC(mac) else { return nil }
    var expires: Date? = nil
    if let lease = fields["lease"], lease.hasPrefix("0x"),
      let seconds = UInt64(lease.dropFirst(2), radix: 16)
    {
      expires = Date(timeIntervalSince1970: TimeInterval(seconds))
    }
    return DHCPLease(
      name: fields["name"], ipAddress: ip, hardwareAddress: normalized, expires: expires)
  }

  /// The address of the newest unexpired lease for `mac` in `text`.
  public static func ip(for mac: String, in text: String, now: Date = Date()) -> String? {
    guard let mac = DHCPLeases.normalizeMAC(mac) else { return nil }
    return parse(text)
      .filter { $0.hardwareAddress == mac && ($0.expires.map { $0 > now } ?? true) }
      .max { ($0.expires ?? .distantPast) < ($1.expires ?? .distantPast) }?
      .ipAddress
  }

  /// `ip(for:in:)` over the file at `path`; nil when it is absent or holds no lease for `mac`.
  public static func lookup(mac: String, path: String = defaultPath) -> String? {
    guard let text = try? String(contentsOf: URL(filePath: path), encoding: .utf8) else {
      return nil
    }
    return ip(for: mac, in: text)
  }

  /// Polls the lease file until a lease for `mac` appears or `timeout` passes.
  public static func waitForIP(
    mac: String, path: String = defaultPath, timeout: Duration,
    interval: Duration = .milliseconds(500)
  ) async -> String? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
      if let ip = lookup(mac: mac, path: path) { return ip }
      if clock.now >= deadline || Task.isCancelled { return nil }
      try? await Task.sleep(for: interval)
    }
  }
}
