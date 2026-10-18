import Foundation
import Testing
import VMLabCore

@Suite struct StartGateTests {
  static let host = SelectorTests.devHost()  // 32 GB

  static func linux(_ id: String? = nil, _ gb: Int) -> Inventory.Guest {
    .init(id: id, profile: .vzLinux, os: .linux, memoryGB: gb)
  }

  static func macos(_ id: String? = nil) -> Inventory.Guest {
    .init(id: id, profile: .vzMacOS, os: .macos, memoryGB: 8)
  }

  static func code(_ error: any Error) -> ErrorCode? { (error as? VMLabError)?.code }

  @Test func memoryLimitCountsRunningGuestsWithTheNumbers() async throws {
    let gate = StartGate()
    let running = Inventory(guests: [Self.linux("a", 16), Self.linux("b", 8)])
    await #expect {
      _ = try await gate.admit(Self.linux("c", 5), running: { running }, host: Self.host)
    } throws: { error in
      (error as? VMLabError)?.data
        == ["requestedGB": .number(5), "freeGB": .number(8), "reserveGB": .number(4)]
    }
    #expect(await gate.inFlight == 0)
    let permit = try await gate.admit(Self.linux("c", 4), running: { running }, host: Self.host)
    #expect(await gate.inFlight == 1)
    await gate.release(permit)
    #expect(await gate.inFlight == 0)
  }

  @Test func admittedStartsCountAgainstTheMemoryBudget() async throws {
    let gate = StartGate()
    let empty: @Sendable () -> Inventory = { .empty }
    let first = try await gate.admit(Self.linux("a", 16), running: empty, host: Self.host)
    await #expect {
      _ = try await gate.admit(Self.linux("b", 16), running: empty, host: Self.host)
    } throws: { Self.code($0) == .limitMemory }
    // Once the first guest is live in the inventory it is not counted twice.
    let live = Inventory(guests: [Self.linux("a", 16)])
    let second = try await gate.admit(Self.linux("b", 12), running: { live }, host: Self.host)
    await gate.release(first)
    await gate.release(second)
  }

  @Test func macOSLimitCountsRunningAndAdmittedGuests() async throws {
    let gate = StartGate()
    let one = Inventory(guests: [Self.macos("m1")])
    let permit = try await gate.admit(Self.macos("m2"), running: { one }, host: Self.host)
    await #expect {
      _ = try await gate.admit(Self.macos("m3"), running: { one }, host: Self.host)
    } throws: { Self.code($0) == .limitMacOSGuests }
    // A Linux guest is not held back by the macOS count.
    await gate.release(
      try await gate.admit(Self.linux("l", 2), running: { one }, host: Self.host))
    await gate.release(permit)
    await gate.release(
      try await gate.admit(Self.macos("m3"), running: { one }, host: Self.host))
  }

  @Test func gateAdmitsAtMostParallelStartsAndHandsSlotsOnInOrder() async throws {
    let gate = StartGate(limits: ResourceLimits(reserveGB: 0, parallelStarts: 2))
    let empty: @Sendable () -> Inventory = { .empty }
    let a = try await gate.admit(Self.linux("a", 1), running: empty, host: Self.host)
    let b = try await gate.admit(Self.linux("b", 1), running: empty, host: Self.host)
    let third = Task { try await gate.admit(Self.linux("c", 1), running: empty, host: Self.host) }
    while await gate.waiting == 0 { await Task.yield() }
    #expect(await gate.inFlight == 2)
    await gate.release(a)
    let c = try await third.value
    #expect(c.guest.id == "c")
    #expect(await gate.inFlight == 2)
    await gate.release(a)  // a second release is a no-op
    #expect(await gate.inFlight == 2)
    await gate.release(b)
    await gate.release(c)
    #expect(await gate.inFlight == 0)
  }

  @Test func defaultGateRunsFourStartsAtOnce() async throws {
    let gate = StartGate()
    let empty: @Sendable () -> Inventory = { .empty }
    var permits: [StartPermit] = []
    for i in 0..<4 {
      permits.append(try await gate.admit(Self.linux("g\(i)", 1), running: empty, host: Self.host))
    }
    let fifth = Task { try await gate.admit(Self.linux("g4", 1), running: empty, host: Self.host) }
    while await gate.waiting == 0 { await Task.yield() }
    #expect(await gate.inFlight == 4)
    await gate.release(permits[0])
    await gate.release(try await fifth.value)
    for permit in permits.dropFirst() { await gate.release(permit) }
    #expect(await gate.inFlight == 0)
  }

  @Test func refusedStartFreesItsSlot() async throws {
    let gate = StartGate(limits: ResourceLimits(parallelStarts: 1))
    let full = Inventory(guests: [Self.linux("a", 28)])
    await #expect {
      _ = try await gate.admit(Self.linux("b", 4), running: { full }, host: Self.host)
    } throws: { Self.code($0) == .limitMemory }
    await gate.release(
      try await gate.admit(Self.linux("b", 4), running: { .empty }, host: Self.host))
  }

  @Test func cancelledWaiterLeavesTheQueue() async throws {
    let gate = StartGate(limits: ResourceLimits(parallelStarts: 1))
    let empty: @Sendable () -> Inventory = { .empty }
    let a = try await gate.admit(Self.linux("a", 1), running: empty, host: Self.host)
    let waiter = Task { try await gate.admit(Self.linux("b", 1), running: empty, host: Self.host) }
    while await gate.waiting == 0 { await Task.yield() }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { _ = try await waiter.value }
    #expect(await gate.waiting == 0)
    await gate.release(a)
    await gate.release(try await gate.admit(Self.linux("c", 1), running: empty, host: Self.host))
  }

  @Test func withStartReleasesOnThrow() async throws {
    struct Boom: Error {}
    let gate = StartGate(limits: ResourceLimits(parallelStarts: 1))
    let empty: @Sendable () -> Inventory = { .empty }
    await #expect(throws: Boom.self) {
      try await gate.withStart(Self.linux("a", 1), running: empty, host: Self.host) {
        throw Boom()
      }
    }
    #expect(await gate.inFlight == 0)
    let value = try await gate.withStart(Self.linux("b", 1), running: empty, host: Self.host) { 7 }
    #expect(value == 7)
  }

  @Test func guestFromRecordUsesTheDefaultMemory() {
    let record = LimitsTests.record(.macos, .stopped)
    #expect(Inventory.Guest(record: record).memoryGB == 8)
    #expect(Inventory.Guest(record: record).id == "vm-aaaaaa")
  }
}
