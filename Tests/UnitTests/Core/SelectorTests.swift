import Foundation
import Testing

@testable import VMLabCore

@Suite struct SelectorTests {
  /// The dev host of Appendix I: M1 Max, 32 GB, not root, Rosetta installed, no nested
  /// virtualization, every slow probe `yes` unless overridden.
  static func devHost(_ overrides: [SlowProbe: ProbeResult] = [:]) -> HostFacts {
    var probes = SlowProbes()
    for probe in SlowProbe.allCases {
      probes[probe] = ProbeRecord(result: overrides[probe] ?? .yes)
    }
    return HostFacts(
      osVersion: "26.6.2", chip: .init(model: "Apple M1 Max", generation: 1), memoryGB: 32,
      freeMemoryGB: 10, freeDiskGB: 200, isRoot: false,
      qemu: .init(present: true, version: "11.1.2", accelerators: ["hvf", "tcg"]),
      tart: .absent, rosettaInstalled: true, nestedSupported: false, runnerSigned: true,
      probes: probes)
  }

  static let arm = GuestSpec(os: .linux, arch: .arm64)
  static let x86 = GuestSpec(os: .linux, arch: .x86_64)
  static let mac = GuestSpec(os: .macos, arch: .arm64)

  static func plan(
    _ guest: GuestSpec, require: [Feature] = [], prefer: [Feature] = [],
    host: HostFacts = devHost(), running: Inventory = .empty
  ) throws -> Result<Plan, Unsatisfiable> {
    select(
      try Requirements(guest: guest, require: require, prefer: prefer), host: host,
      running: running)
  }

  static func profile(_ result: Result<Plan, Unsatisfiable>) -> Profile? {
    try? result.get().profile
  }

  static func failure(_ result: Result<Plan, Unsatisfiable>) -> Unsatisfiable? {
    if case .failure(let u) = result { return u }
    return nil
  }

  // MARK: Appendix I worked examples, in table order

  @Test func linuxWithNothingRequiredIsVZLinux() throws {
    #expect(Self.profile(try Self.plan(Self.arm)) == .vzLinux)
  }

  @Test func serialAndGDBIsQEMUHVF() throws {
    #expect(Self.profile(try Self.plan(Self.arm, require: [.serial, .gdb])) == .qemuHVF)
  }

  @Test func gdbAndLiveCheckpointWithoutHVFSnapshotsIsTCG() throws {
    let plan = try Self.plan(
      Self.arm, require: [.gdb, .checkpointLive],
      host: Self.devHost([.qemuHVFLiveSnapshot: .no])
    ).get()
    #expect(plan.profile == .qemuTCG)
    #expect(plan.notes.contains { $0.contains("slow") })
  }

  @Test func serialAndRosettaIsVZLinux() throws {
    #expect(Self.profile(try Self.plan(Self.arm, require: [.serial, .rosetta])) == .vzLinux)
  }

  @Test func rosettaAndGDBIsUnsatisfiable() throws {
    let u = try #require(Self.failure(try Self.plan(Self.arm, require: [.rosetta, .gdb])))
    #expect(u.eliminated == [.rosetta: [.qemuHVF, .qemuTCG], .gdb: [.vzLinux]])
    #expect(
      u.suggestions == [
        .init(drop: [.gdb], profile: .vzLinux), .init(drop: [.rosetta], profile: .qemuHVF),
      ])
    #expect(u.error.code == .unsatisfiable)
  }

  @Test func x86PrebootAndFirmwareIsTCG() throws {
    #expect(
      Self.profile(try Self.plan(Self.x86, require: [.guiPreboot, .customFirmware])) == .qemuTCG)
  }

  @Test func x86WithAcceleratedGraphicsIsUnsatisfiable() throws {
    let u = try #require(Self.failure(try Self.plan(Self.x86, require: [.guiAccel])))
    #expect(u.eliminated == [.guiAccel: [.qemuTCG]])
    #expect(u.suggestions == [.init(drop: [.guiAccel], profile: .qemuTCG)])
  }

  @Test func noNetworkWithAForwardedPortIsInvalid() {
    #expect {
      _ = try Requirements(
        guest: Self.arm, require: [.netPortForward], network: NetworkSpec(mode: .disabled))
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
  }

  @Test func macOSWithNothingRequiredIsVZMacOS() throws {
    #expect(Self.profile(try Self.plan(Self.mac)) == .vzMacOS)
  }

  @Test func macOSWithSerialIsInvalid() {
    #expect {
      _ = try Requirements(guest: Self.mac, require: [.serial])
    } throws: { ($0 as? VMLabError)?.code == .invalidRequest }
  }

  @Test func thirdMacOSGuestHitsTheLimit() throws {
    let running = Inventory(guests: [
      .init(profile: .vzMacOS, os: .macos, memoryGB: 8),
      .init(profile: .vzMacOS, os: .macos, memoryGB: 8),
    ])
    let u = try #require(
      Self.failure(
        try Self.plan(Self.mac, require: [.gui, .checkpointDisk], running: running)))
    #expect(u.error.code == .limitMacOSGuests)
    #expect(u.error.data["running"] == .number(2))
  }

  @Test func fastNetworkWithoutVmnetIsVZLinux() throws {
    let host = Self.devHost([.qemuVmnet: .no])
    #expect(Self.profile(try Self.plan(Self.arm, require: [.netFast], host: host)) == .vzLinux)
  }

  /// Appendix I listed only `drop [net_fast] → qemu-hvf`; dropping `gdb` also leaves vz-linux,
  /// which has `net_fast`, so both are suggested (the appendix row was corrected).
  @Test func fastNetworkAndGDBWithoutRootIsUnsatisfiable() throws {
    let host = Self.devHost([.qemuVmnet: .no])
    let u = try #require(
      Self.failure(try Self.plan(Self.arm, require: [.netFast, .gdb], host: host)))
    #expect(u.eliminated == [.netFast: [.qemuHVF, .qemuTCG], .gdb: [.vzLinux]])
    #expect(
      u.suggestions == [
        .init(drop: [.gdb], profile: .vzLinux), .init(drop: [.netFast], profile: .qemuHVF),
      ])
  }

  @Test func nestedVirtualizationOnM1IsTCG() throws {
    let plan = try Self.plan(Self.arm, require: [.nestedVirt]).get()
    #expect(plan.profile == .qemuTCG)
    #expect(plan.notes.contains { $0.contains("emulated") && $0.contains("very slow") })
    #expect(plan.notes.contains { $0.contains("vz-linux") && $0.contains("M3") })
  }

  @Test func unknownLiveSnapshotProbeIsReportedUnverified() throws {
    let plan = try Self.plan(
      Self.arm, require: [.gdb], prefer: [.checkpointLive],
      host: Self.devHost([.qemuHVFLiveSnapshot: .unknown])
    ).get()
    #expect(plan.profile == .qemuHVF)
    #expect(plan.unverified == [.checkpointLive])
    #expect(plan.preferredDenied == [.checkpointLive])
    #expect(!plan.grants(.checkpointLive))
  }

  @Test func preferredSerialStaysOnVZLinux() throws {
    let plan = try Self.plan(Self.arm, prefer: [.serial]).get()
    #expect(plan.profile == .vzLinux)
    #expect(plan.preferredDenied.isEmpty)
  }

  @Test func execAgentIsQEMUHVF() throws {
    #expect(Self.profile(try Self.plan(Self.arm, require: [.execAgent])) == .qemuHVF)
  }

  @Test func fleetOfSixEightGBGuestsHitsTheMemoryLimit() throws {
    let request = try Requirements(guest: Self.arm, resources: ResourceSpec(memoryGB: 8))
    var running = Inventory.empty
    var refusal: VMLabError?
    for _ in 0..<6 {
      switch select(request, host: Self.devHost(), running: running) {
      case .success(let plan):
        running = running.adding(.init(profile: plan.profile, os: .linux, memoryGB: 8))
      case .failure(let u):
        refusal = u.error
      }
      if refusal != nil { break }
    }
    #expect(running.guests.count == 3)
    let error = try #require(refusal)
    #expect(error.code == .limitMemory)
    #expect(
      error.data == ["requestedGB": .number(8), "freeGB": .number(8), "reserveGB": .number(4)])
  }

  @Test func manyGuestsWithAcceleratedGraphicsIsVZLinux() throws {
    #expect(Self.profile(try Self.plan(Self.arm, require: [.manyGuests, .guiAccel])) == .vzLinux)
  }

  @Test func macOSWithManyGuestsIsUnsatisfiable() throws {
    let u = try #require(Self.failure(try Self.plan(Self.mac, require: [.manyGuests])))
    #expect(u.eliminated == [.manyGuests: [.vzMacOS]])
    #expect(u.suggestions == [.init(drop: [.manyGuests], profile: .vzMacOS)])
  }

  // MARK: Plan contents and errors

  @Test func planFeaturesAreRequiredPlusEveryYes() throws {
    let plan = try Self.plan(Self.arm).get()
    let caps = Capabilities.capabilities(of: .vzLinux, host: Self.devHost())
    #expect(plan.features == Feature.allCases.filter { caps[$0] == .yes })
    #expect(plan.resources == ResourceSpec(cpus: 2, memoryGB: 4, diskGB: 32))
    #expect(
      try Self.plan(Self.mac).get().resources == ResourceSpec(cpus: 4, memoryGB: 8, diskGB: nil))
  }

  @Test func impliedFeaturesAreRequired() throws {
    let request = try Requirements(
      guest: Self.arm, boot: BootSpec(mode: .firmware, firmware: "/tmp/fw.bin"))
    #expect(
      (try select(request, host: Self.devHost(), running: .empty).get()).profile == .qemuHVF)
  }

  @Test func forwardedPortOnVZGetsANote() throws {
    let plan = try Self.plan(Self.arm, require: [.netPortForward]).get()
    #expect(plan.profile == .vzLinux)
    #expect(plan.notes.contains { $0.contains("host-reachable address") })
  }

  @Test func unknownProbeAloneIsUnverifiedCapability() throws {
    // gdb with qemu_hvf_gdb unknown still lands on TCG and says why.
    let host = Self.devHost([.qemuHVFGDB: .unknown])
    let plan = try Self.plan(Self.arm, require: [.gdb], host: host).get()
    #expect(plan.profile == .qemuTCG)
    #expect(plan.unverified == [.gdb])
    // With TCG ruled out too, the unknown probe is what stands in the way.
    let u = try #require(
      Self.failure(try Self.plan(Self.arm, require: [.gdb, .guiAccel], host: host)))
    #expect(u.unverified.isEmpty)
    let blocked = try #require(
      Self.failure(
        try Self.plan(
          Self.arm, require: [.gdb, .netFast],
          host: Self.devHost([.qemuHVFGDB: .unknown, .qemuVmnet: .unknown]))))
    #expect(blocked.error.code == .unverifiedCapability)
    #expect(blocked.error.data["feature"] == .string("gdb"))
    #expect(blocked.error.data["probe"] == .string("qemu_hvf_gdb"))
  }

  @Test func allowUnverifiedTreatsUnknownAsYes() throws {
    let host = Self.devHost([.qemuHVFLiveSnapshot: .unknown])
    let request = try Requirements(guest: Self.arm, require: [.gdb, .checkpointLive])
    let strict = try select(request, host: host, running: .empty).get()
    #expect(strict.profile == .qemuTCG)
    let lenient = try select(request, host: host, running: .empty, allowUnverified: true).get()
    #expect(lenient.profile == .qemuHVF)
    #expect(lenient.allowUnverified)
    #expect(lenient.unverified == [.checkpointLive])
    #expect(lenient.notes.contains { $0.contains("allowUnverified") })
  }

  @Test func unsatisfiableErrorCarriesEliminatedAndSuggestions() throws {
    let u = try #require(Self.failure(try Self.plan(Self.arm, require: [.rosetta, .gdb])))
    let error = u.error
    #expect(
      error.data["eliminated"]
        == .object([
          "rosetta": .array([.string("qemu-hvf"), .string("qemu-tcg")]),
          "gdb": .array([.string("vz-linux")]),
        ]))
    #expect(
      error.data["suggestions"]
        == .array([
          .object(["drop": .array([.string("gdb")]), "profile": .string("vz-linux")]),
          .object(["drop": .array([.string("rosetta")]), "profile": .string("qemu-hvf")]),
        ]))
    #expect(error.message.contains("Rosetta"))
  }

  @Test func suggestionsAreMinimalAndCapped() throws {
    // Only the features that rule out a profile are dropped, and no suggestion contains another.
    let u = try #require(
      Self.failure(try Self.plan(Self.x86, require: [.guiAccel, .gdb, .serial, .execSSH])))
    #expect(u.suggestions == [.init(drop: [.guiAccel], profile: .qemuTCG)])
    let combos = try #require(
      Self.failure(
        try Self.plan(
          Self.arm, require: [.rosetta, .gdb, .execAgent, .introspection, .memoryDump])))
    #expect(combos.suggestions.count <= 5)
    for s in combos.suggestions {
      #expect(!combos.suggestions.contains { $0 != s && Set($0.drop).isStrictSubset(of: s.drop) })
    }
    #expect(combos.suggestions.first == .init(drop: [.rosetta], profile: .qemuHVF))
  }

  @Test func combinationsAreLexicographic() {
    #expect(
      ProfileSelector.combinations(4, 2) == [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]])
  }

  // MARK: Property test

  /// SplitMix64, so the 500 cases are the same on every run.
  struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  @Test func randomRequestsYieldPlansThatSatisfyEveryRequirement() throws {
    var rng = SeededRNG(state: 103)
    let guests = [Self.arm, Self.x86, Self.mac, GuestSpec(os: .linux, arch: .riscv64)]
    var checked = 0
    var plans = 0
    while checked < 500 {
      let guest = guests.randomElement(using: &rng)!
      let require = Feature.allCases.filter { _ in Int.random(in: 0..<9, using: &rng) == 0 }
      let prefer = Feature.allCases.filter { _ in Int.random(in: 0..<9, using: &rng) == 0 }
      let memory = Int.random(in: 1...16, using: &rng)
      guard
        let request = try? Requirements(
          guest: guest, require: require, prefer: prefer,
          resources: ResourceSpec(memoryGB: memory))
      else { continue }
      checked += 1
      var overrides: [SlowProbe: ProbeResult] = [:]
      for probe in SlowProbe.allCases {
        overrides[probe] = [.yes, .no, .unknown].randomElement(using: &rng)!
      }
      let host = Self.devHost(overrides)
      let running = Inventory(
        guests: (0..<Int.random(in: 0...4, using: &rng)).map { _ in
          Bool.random(using: &rng)
            ? .init(profile: .vzMacOS, os: .macos, memoryGB: 8)
            : .init(profile: .vzLinux, os: .linux, memoryGB: Int.random(in: 1...8, using: &rng))
        })
      let allow = Bool.random(using: &rng)
      switch select(request, host: host, running: running, allowUnverified: allow) {
      case .success(let plan):
        plans += 1
        let caps = Capabilities.capabilities(of: plan.profile, host: host, allowUnverified: allow)
        #expect(Capabilities.supports(guest, on: plan.profile))
        for feature in require {
          #expect(caps[feature] == .yes, "\(feature) on \(plan.profile)")
          #expect(plan.grants(feature))
        }
        #expect(plan.features.allSatisfy { caps[$0] == .yes })
        if plan.profile == .vzMacOS { #expect(running.macOSGuests < 2) }
        #expect(Double(running.memoryGB + memory) <= host.memoryGB - 4)
      case .failure(let u):
        if u.limit == nil {
          // No profile has every required feature, and every suggestion really works.
          let candidates = Profile.allCases.filter { Capabilities.supports(guest, on: $0) }
          for profile in candidates {
            let caps = Capabilities.capabilities(of: profile, host: host, allowUnverified: allow)
            #expect(!require.allSatisfy { caps[$0] == .yes })
          }
          #expect(u.suggestions.count <= 5)
          for s in u.suggestions {
            #expect(s.drop.count <= 3)
            let caps = Capabilities.capabilities(of: s.profile, host: host, allowUnverified: allow)
            #expect(require.filter { !s.drop.contains($0) }.allSatisfy { caps[$0] == .yes })
          }
        }
      }
    }
    #expect(plans > 50)
  }

  // MARK: R-504 desktop provisioning

  @Test func guiOnVZLinuxInstallsTheDesktop() throws {
    let plan = try Self.plan(Self.arm, require: [.gui]).get()
    #expect(plan.profile == .vzLinux)
    #expect(plan.provisionsDesktop)
    #expect(plan.startupTier == Profile.vzLinux.startupTier + 1)
    #expect(plan.estimatedStartupSeconds == 15 + Plan.desktopInstallSeconds)
    #expect(plan.notes.contains { $0.contains("desktop") && $0.contains("first boot") })
  }

  @Test func guiAloneOnQEMUInstallsNothing() throws {
    let plan = try Self.plan(Self.arm, require: [.gui, .gdb]).get()
    #expect(plan.profile == .qemuHVF)
    #expect(!plan.provisionsDesktop)
    #expect(plan.startupTier == Profile.qemuHVF.startupTier)
    #expect(plan.estimatedStartupSeconds == 20)
    #expect(!plan.notes.contains { $0.contains("desktop") })
  }

  @Test func guiDesktopOnQEMUInstallsTheDesktop() throws {
    let plan = try Self.plan(Self.arm, require: [.guiDesktop, .gdb]).get()
    #expect(plan.profile == .qemuHVF)
    #expect(plan.provisionsDesktop)
    #expect(plan.startupTier == Profile.qemuHVF.startupTier + 1)
    #expect(plan.estimatedStartupSeconds == 20 + Plan.desktopInstallSeconds)
  }

  @Test func macOSNeverInstallsADesktop() throws {
    let plan = try Self.plan(Self.mac, require: [.gui]).get()
    #expect(!plan.provisionsDesktop)
    #expect(plan.startupTier == Profile.vzMacOS.startupTier)
  }

  @Test func storedPlanWithoutStartupTierDecodes() throws {
    let plan = try Self.plan(Self.arm, require: [.gui]).get()
    guard
      case .object(var object) = try JSONDecoder().decode(
        JSONValue.self, from: JSONEncoder().encode(plan))
    else { return }
    object["startupTier"] = nil
    let decoded = try JSONDecoder().decode(
      Plan.self, from: JSONEncoder().encode(JSONValue.object(object)))
    #expect(decoded == plan)
  }
}
