import Foundation
import Testing
import VMLabCore

@Suite struct FleetsTests {
  static let plan = Plan(
    profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
    resources: ResourceSpec(cpus: 2, memoryGB: 4, diskGB: 8), features: [.execSSH],
    estimatedStartupSeconds: 20)

  static func host(memoryGB: Double = 32) -> HostFacts {
    var facts = CapabilitiesTests.host(probes: .yes)
    facts.memoryGB = memoryGB
    return facts
  }

  @Test func membersAreNamedInOrder() throws {
    #expect(FleetPlanning.memberNames("node", count: 3) == ["node-1", "node-2", "node-3"])
    try FleetPlanning.checkName("cluster-a")
    for bad in ["Cluster", "a_b", "", String(repeating: "x", count: 29)] {
      #expect(throws: VMLabError.self) { try FleetPlanning.checkName(bad) }
    }
  }

  /// The budget is for every member at once: 7 × 4 GB fits in 32 GB with the 4 GB reserve, 8 do
  /// not, and the refusal names the whole fleet's memory.
  @Test func budgetCoversAllMembersAtOnce() throws {
    let limits = ResourceLimits.defaults
    try FleetPlanning.checkBudget(
      plan: Self.plan, count: 7, running: .empty, host: Self.host(), limits: limits)
    #expect {
      try FleetPlanning.checkBudget(
        plan: Self.plan, count: 8, running: .empty, host: Self.host(), limits: limits)
    } throws: { error in
      guard let error = error as? VMLabError else { return false }
      return error.code == .limitMemory && error.data["requestedGB"] == .number(32)
        && error.data["count"] == .number(8)
    }
    let running = Inventory(guests: [
      Inventory.Guest(profile: .qemuHVF, os: .linux, memoryGB: 16)
    ])
    #expect(throws: VMLabError.self) {
      try FleetPlanning.checkBudget(
        plan: Self.plan, count: 4, running: running, host: Self.host(), limits: limits)
    }
    #expect {
      try FleetPlanning.checkBudget(
        plan: Self.plan, count: 0, running: .empty, host: Self.host(), limits: limits)
    } throws: { ($0 as? VMLabError)?.data["field"] == .string("count") }
  }

  @Test func macOSFleetsRespectTheTwoGuestLimit() throws {
    let plan = Plan(
      profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64),
      resources: ResourceSpec(cpus: 4, memoryGB: 4), features: [], estimatedStartupSeconds: 60)
    try FleetPlanning.checkBudget(
      plan: plan, count: 2, running: .empty, host: Self.host(), limits: .defaults)
    #expect {
      try FleetPlanning.checkBudget(
        plan: plan, count: 3, running: .empty, host: Self.host(), limits: .defaults)
    } throws: { ($0 as? VMLabError)?.code == .limitMacOSGuests }
  }

  @Test func recordsRoundTrip() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-fleet-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = FleetStore(home: home)
    let fleet = FleetRecord(
      name: "web", createdAt: Date(), plan: Self.plan, image: "debian-13-arm64", segment: "web",
      autoSegment: true,
      members: [
        FleetMember(name: "web-1", vm: "vm-aaaaaa"),
        FleetMember(
          name: "web-2", error: VMLabError(code: .engineError, message: "boom", hint: "")),
      ])
    try store.save(fleet)
    #expect(try store.load("web") == fleet)
    #expect(store.list().map(\.name) == ["web"])
    store.remove("web")
    #expect(!store.exists("web"))
  }
}
