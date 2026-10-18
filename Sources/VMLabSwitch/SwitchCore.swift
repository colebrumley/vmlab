/// A 48-bit Ethernet address.
public struct MACAddress: Hashable, Sendable, CustomStringConvertible {
  public let bytes: [UInt8]

  public init?(_ bytes: some Collection<UInt8>) {
    guard bytes.count == 6 else { return nil }
    self.bytes = Array(bytes)
  }

  /// Group (multicast or broadcast) addresses have the low bit of the first octet set.
  public var isGroup: Bool { bytes[0] & 1 == 1 }

  public var description: String {
    bytes.map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0" + hex : hex
    }.joined(separator: ":")
  }
}

/// Counters a switch exposes on `stats.sock`.
public struct SwitchStats: Codable, Sendable, Equatable {
  /// Frames that reached the switch, dropped or not.
  public var received = 0
  /// Frames delivered to exactly one learned port.
  public var unicast = 0
  /// Frames delivered to every port but the sender (broadcast, multicast, unknown destination).
  public var flooded = 0
  /// Frames whose destination was learned on the port they came from.
  public var filtered = 0
  /// Frames shorter than an Ethernet header or with a group source address.
  public var malformed = 0
  /// Frames over `SwitchCore.maxFrameSize` bytes.
  public var oversized = 0
  /// Deliveries a port could not take because its receive buffer was full.
  public var congested = 0
  /// Datagrams from a sender with no bound address, which the switch cannot answer.
  public var unaddressable = 0
  /// Frames from a new source address not learned because the table held `SwitchCore.maxMACs`.
  public var unlearned = 0
  public var ports = 0
  public var macs = 0

  public init() {}
}

/// The forwarding logic of a learning Ethernet switch, with no sockets: ports are integers.
public struct SwitchCore: Sendable {
  public typealias PortID = Int

  /// Frames over this many bytes are dropped and counted.
  public static let maxFrameSize = 1600
  /// Destination, source and EtherType.
  public static let headerSize = 14
  /// The most addresses the table holds. A guest chooses its frames' source addresses, so
  /// without a cap one guest could grow the table, and the switch's memory, without bound.
  public static let maxMACs = 4096

  public enum Decision: Equatable, Sendable {
    case deliver([PortID])
    case drop
  }

  /// A learned address is forgotten after this many seconds without a frame from it.
  public var agingSeconds: Double
  public private(set) var ports: Set<PortID> = []
  public private(set) var stats = SwitchStats()
  private var table: [MACAddress: (port: PortID, seen: Double)] = [:]
  /// When the full table was last swept of aged entries; sweeps run at most once a second.
  private var lastSweep: Double?

  public init(agingSeconds: Double = 300) {
    self.agingSeconds = agingSeconds
  }

  public mutating func addPort(_ port: PortID) {
    ports.insert(port)
    stats.ports = ports.count
  }

  /// Removes a port and every address learned on it.
  public mutating func removePort(_ port: PortID) {
    ports.remove(port)
    table = table.filter { $0.value.port != port }
    stats.ports = ports.count
    stats.macs = table.count
  }

  /// The port an address was last seen on, if it has not aged out.
  public func port(for mac: MACAddress, now: Double) -> PortID? {
    guard let entry = table[mac], now - entry.seen <= agingSeconds else { return nil }
    return entry.port
  }

  public mutating func countCongested() { stats.congested += 1 }
  public mutating func countUnaddressable() { stats.unaddressable += 1 }

  /// Learns the source of a frame that arrived on `port` and says which ports receive it.
  public mutating func forward(_ frame: some Collection<UInt8>, from port: PortID, now: Double)
    -> Decision
  {
    stats.received += 1
    guard frame.count <= Self.maxFrameSize else {
      stats.oversized += 1
      return .drop
    }
    guard frame.count >= Self.headerSize, ports.contains(port),
      let destination = MACAddress(frame.prefix(6)),
      let source = MACAddress(frame.dropFirst(6).prefix(6)), !source.isGroup
    else {
      stats.malformed += 1
      return .drop
    }
    learn(source, on: port, now: now)

    if !destination.isGroup, let target = self.port(for: destination, now: now) {
      if target == port {
        stats.filtered += 1
        return .drop
      }
      stats.unicast += 1
      return .deliver([target])
    }
    stats.flooded += 1
    return .deliver(ports.filter { $0 != port }.sorted())
  }

  /// Records `source` on `port`. Known addresses are always refreshed; a new one is learned only
  /// while the table has room, after sweeping aged entries from a full table. Otherwise frames
  /// to it keep flooding, which is correct, only less efficient.
  private mutating func learn(_ source: MACAddress, on port: PortID, now: Double) {
    if table[source] == nil, table.count >= Self.maxMACs {
      if lastSweep.map({ now - $0 >= 1 }) ?? true {
        lastSweep = now
        table = table.filter { now - $0.value.seen <= agingSeconds }
      }
      if table.count >= Self.maxMACs {
        stats.unlearned += 1
        stats.macs = table.count
        return
      }
    }
    table[source] = (port, now)
    stats.macs = table.count
  }
}
