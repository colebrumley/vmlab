import Testing
import VMLabSwitch

@Suite struct SwitchCoreTests {
  static let broadcast: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
  static func mac(_ n: UInt8) -> [UInt8] { [0x52, 0x54, 0x00, 0x00, 0x00, n] }
  static func frame(to dst: [UInt8], from src: [UInt8], payload: Int = 46) -> [UInt8] {
    dst + src + [0x08, 0x00] + [UInt8](repeating: 0xab, count: payload)
  }

  static func core(ports: [Int] = [1, 2, 3]) -> SwitchCore {
    var core = SwitchCore()
    for port in ports { core.addPort(port) }
    return core
  }

  @Test func broadcastFloodsEveryOtherPort() {
    var core = Self.core()
    let decision = core.forward(Self.frame(to: Self.broadcast, from: Self.mac(1)), from: 1, now: 0)
    #expect(decision == .deliver([2, 3]))
    #expect(core.stats.flooded == 1)
    #expect(core.port(for: MACAddress(Self.mac(1))!, now: 0) == 1)
  }

  @Test func unicastGoesToTheLearnedPortOnly() {
    var core = Self.core()
    _ = core.forward(Self.frame(to: Self.broadcast, from: Self.mac(1)), from: 1, now: 0)
    let decision = core.forward(Self.frame(to: Self.mac(1), from: Self.mac(2)), from: 2, now: 1)
    #expect(decision == .deliver([1]))
    #expect(core.stats.unicast == 1)
    #expect(core.stats.macs == 2)
  }

  @Test func unknownUnicastAndMulticastFlood() {
    var core = Self.core()
    #expect(
      core.forward(Self.frame(to: Self.mac(9), from: Self.mac(1)), from: 1, now: 0)
        == .deliver([2, 3]))
    let multicast: [UInt8] = [0x01, 0x00, 0x5e, 0x00, 0x00, 0x01]
    #expect(
      core.forward(Self.frame(to: multicast, from: Self.mac(2)), from: 2, now: 0)
        == .deliver([1, 3]))
    #expect(core.stats.flooded == 2)
  }

  @Test func destinationOnTheSendingPortIsFiltered() {
    var core = Self.core()
    _ = core.forward(Self.frame(to: Self.broadcast, from: Self.mac(1)), from: 1, now: 0)
    #expect(core.forward(Self.frame(to: Self.mac(1), from: Self.mac(4)), from: 1, now: 0) == .drop)
    #expect(core.stats.filtered == 1)
  }

  @Test func malformedFramesAreCountedAndDropped() {
    var core = Self.core()
    #expect(core.forward([UInt8](repeating: 0, count: 13), from: 1, now: 0) == .drop)
    #expect(core.forward([], from: 1, now: 0) == .drop)
    // A group address cannot be a source, and must not be learned.
    #expect(
      core.forward(Self.frame(to: Self.mac(1), from: Self.broadcast), from: 2, now: 0) == .drop)
    #expect(core.stats.malformed == 3)
    #expect(core.stats.received == 3)
    #expect(core.stats.macs == 0)
  }

  @Test func framesOverSixteenHundredBytesAreDropped() {
    var core = Self.core()
    let largest = Self.frame(to: Self.broadcast, from: Self.mac(1), payload: 1600 - 14)
    #expect(core.forward(largest, from: 1, now: 0) == .deliver([2, 3]))
    #expect(core.forward(largest + [0], from: 1, now: 0) == .drop)
    #expect(core.stats.oversized == 1)
  }

  @Test func removingAPortForgetsItsAddresses() {
    var core = Self.core()
    _ = core.forward(Self.frame(to: Self.broadcast, from: Self.mac(1)), from: 1, now: 0)
    core.removePort(1)
    #expect(core.stats.ports == 2)
    #expect(core.stats.macs == 0)
    #expect(
      core.forward(Self.frame(to: Self.mac(1), from: Self.mac(2)), from: 2, now: 0) == .deliver([3])
    )
  }

  @Test func learnedAddressesAgeOut() {
    var core = SwitchCore(agingSeconds: 10)
    for port in [1, 2, 3] { core.addPort(port) }
    _ = core.forward(Self.frame(to: Self.broadcast, from: Self.mac(1)), from: 1, now: 0)
    #expect(
      core.forward(Self.frame(to: Self.mac(1), from: Self.mac(2)), from: 2, now: 5) == .deliver([1])
    )
    #expect(
      core.forward(Self.frame(to: Self.mac(1), from: Self.mac(2)), from: 2, now: 11)
        == .deliver([1, 3]))
  }

  @Test func macAddressFormatting() {
    #expect(MACAddress(Self.mac(10))?.description == "52:54:00:00:00:0a")
    #expect(MACAddress([1, 2, 3]) == nil)
  }

  static func spoofed(_ n: Int) -> [UInt8] {
    [
      0x02, 0x00, UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff),
      UInt8(n & 0xff),
    ]
  }

  /// A guest controls the source MAC of every frame it sends; the table must not grow without
  /// bound (aging alone was only checked on lookup).
  @Test func spoofedSourceMACsDoNotGrowTheTableWithoutBound() {
    var core = Self.core(ports: [1, 2])
    for n in 0..<100_000 {
      _ = core.forward(Self.frame(to: Self.broadcast, from: Self.spoofed(n)), from: 1, now: 0)
    }
    #expect(core.stats.macs <= SwitchCore.maxMACs)
    #expect(core.stats.macs == SwitchCore.maxMACs)
    #expect(core.stats.unlearned == 100_000 - SwitchCore.maxMACs)
  }

  @Test func aFullTableStillRefreshesKnownAddressesAndFloodsUnknownOnes() {
    var core = Self.core(ports: [1, 2, 3])
    for n in 0..<SwitchCore.maxMACs {
      _ = core.forward(Self.frame(to: Self.broadcast, from: Self.spoofed(n)), from: 1, now: 0)
    }
    // A known address moving port is still re-learned while the table is full.
    _ = core.forward(Self.frame(to: Self.broadcast, from: Self.spoofed(0)), from: 2, now: 1)
    #expect(core.port(for: MACAddress(Self.spoofed(0))!, now: 1) == 2)
    // A new one is not learned, and traffic to it floods.
    _ = core.forward(Self.frame(to: Self.broadcast, from: Self.mac(9)), from: 3, now: 1)
    #expect(core.port(for: MACAddress(Self.mac(9))!, now: 1) == nil)
    #expect(core.stats.unlearned == 1)
    let decision = core.forward(Self.frame(to: Self.mac(9), from: Self.spoofed(0)), from: 2, now: 1)
    #expect(decision == .deliver([1, 3]))
  }

  @Test func aFullTableSweepsAgedEntriesBeforeRefusing() {
    var core = SwitchCore(agingSeconds: 10)
    core.addPort(1)
    core.addPort(2)
    for n in 0..<SwitchCore.maxMACs {
      _ = core.forward(Self.frame(to: Self.broadcast, from: Self.spoofed(n)), from: 1, now: 0)
    }
    _ = core.forward(Self.frame(to: Self.broadcast, from: Self.mac(9)), from: 2, now: 11)
    #expect(core.port(for: MACAddress(Self.mac(9))!, now: 11) == 2)
    #expect(core.stats.macs == 1)
    #expect(core.stats.unlearned == 0)
  }
}
