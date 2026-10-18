import Foundation
import Testing
import VMLabCore

@Suite struct LimitsTests {
  static let host = SelectorTests.devHost()

  static func record(_ os: GuestSpec.OS, _ state: VMState, memoryGB: Int? = nil) -> VMRecord {
    VMRecord(
      id: "vm-aaaaaa", profile: os == .macos ? .vzMacOS : .vzLinux,
      guest: GuestSpec(os: os, arch: .arm64), features: [],
      resources: ResourceSpec(memoryGB: memoryGB), state: state)
  }

  @Test func inventoryCountsOnlyLiveRecordsWithDefaultMemory() {
    let inventory = Inventory(records: [
      Self.record(.macos, .running), Self.record(.linux, .paused, memoryGB: 6),
      Self.record(.linux, .stopped, memoryGB: 16), Self.record(.linux, .running),
    ])
    #expect(inventory.guests.count == 3)
    #expect(inventory.macOSGuests == 1)
    #expect(inventory.memoryGB == 8 + 6 + 4)
  }

  @Test func storeInventoryReadsTheRecords() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-limits-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    _ = try store.create(Self.record(.linux, .running, memoryGB: 3))
    _ = try store.create(Self.record(.linux, .created))
    #expect(store.inventory().memoryGB == 3)
  }

  @Test func macOSLimitAppliesOnlyToMacOSProfiles() throws {
    let limits = ResourceLimits.defaults
    let two = Inventory(
      guests: Array(repeating: .init(profile: .vzMacOS, os: .macos, memoryGB: 8), count: 2))
    try limits.checkMacOSGuests(profile: .vzLinux, running: two)
    try limits.checkMacOSGuests(profile: .vzMacOS, running: Inventory(guests: [two.guests[0]]))
    #expect {
      try limits.checkMacOSGuests(profile: .vzMacOS, running: two)
    } throws: { ($0 as? VMLabError)?.code == .limitMacOSGuests }
  }

  @Test func memoryBudgetKeepsTheReserveFree() throws {
    let limits = ResourceLimits.defaults
    let running = Inventory(guests: [.init(profile: .vzLinux, os: .linux, memoryGB: 20)])
    try limits.checkMemory(requestedGB: 8, running: running, host: Self.host)  // 32 - 28 = 4
    #expect {
      try limits.checkMemory(requestedGB: 9, running: running, host: Self.host)
    } throws: { error in
      let e = error as? VMLabError
      return e?.code == .limitMemory
        && e?.data == ["requestedGB": .number(9), "freeGB": .number(12), "reserveGB": .number(4)]
    }
    try ResourceLimits(reserveGB: 2).checkMemory(requestedGB: 9, running: running, host: Self.host)
  }

  @Test func defaultsFollowAppendixG() {
    #expect(
      ResourceLimits.defaults == ResourceLimits(reserveGB: 4, maxMacOSGuests: 2, parallelStarts: 4))
    #expect(
      ResourceLimits.resolve(ResourceSpec(cpus: 6), for: .linux)
        == ResourceSpec(cpus: 6, memoryGB: 4, diskGB: 32))
  }
}
