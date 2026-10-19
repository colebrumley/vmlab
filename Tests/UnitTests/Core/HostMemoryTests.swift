import Foundation
import Testing
import VMLabCore

/// Host memory pressure at start: the pressure level, the available memory and the guests of
/// other homes and servers, all read through fixtures.
@Suite struct HostMemoryTests {
  static let host = StartGateTests.host  // 32 GB, 4 GB reserve

  static func reader(
    _ pressure: MemoryPressure = .normal, availableGB: Double = 20, guests: [HostGuestProcess] = []
  ) -> HostMemoryGuard {
    HostMemoryGuard(
      reader: FixedHostMemory(
        HostMemorySnapshot(pressure: pressure, availableGB: availableGB, guests: guests)))
  }

  static func refusal(_ error: any Error) -> VMLabError? {
    guard let error = error as? VMLabError, error.code == .limitMemory else { return nil }
    return error
  }

  @Test func normalPressureAdmitsAndWarnOrCriticalRefuses() async throws {
    let ok = StartGate(hostMemory: Self.reader(.normal))
    await ok.release(
      try await ok.admit(StartGateTests.linux("a", 4), running: { .empty }, host: Self.host))
    for level in [MemoryPressure.warn, .critical] {
      let gate = StartGate(hostMemory: Self.reader(level))
      await #expect {
        _ = try await gate.admit(StartGateTests.linux("a", 4), running: { .empty }, host: Self.host)
      } throws: { error in
        guard let error = Self.refusal(error) else { return false }
        return error.data["pressureLevel"] == .string(level.name)
          && error.data["availableGB"] == .number(20) && error.data["requestedGB"] == .number(4)
          && error.data["reserveGB"] == .number(4) && error.data["hostGuests"] == .number(0)
          && error.hint.contains("vm_list")
      }
      #expect(await gate.inFlight == 0)
    }
  }

  @Test func availableMemoryMustCoverTheGuestAndTheReserve() async throws {
    let gate = StartGate(hostMemory: Self.reader(availableGB: 9))
    let a = try await gate.admit(StartGateTests.linux("a", 5), running: { .empty }, host: Self.host)
    // 9 GB available, 5 GB in flight: 4 GB left, short of 1 GB + 4 GB reserve.
    await #expect {
      _ = try await gate.admit(StartGateTests.linux("b", 1), running: { .empty }, host: Self.host)
    } throws: { error in
      guard let error = Self.refusal(error) else { return false }
      return error.data["availableGB"] == .number(4) && error.data["requestedGB"] == .number(1)
        && error.data["pressureLevel"] == .string("normal")
    }
    await gate.release(a)
    await gate.release(
      try await gate.admit(StartGateTests.linux("b", 5), running: { .empty }, host: Self.host))
    await #expect {
      _ = try await gate.admit(StartGateTests.linux("c", 6), running: { .empty }, host: Self.host)
    } throws: { Self.refusal($0) != nil }
  }

  @Test func guestsOfOtherHomesCountAgainstTheBudget() async throws {
    // 6 × 4 GB QEMU guests started from other homes: 24 of 28 budgeted GB taken.
    let foreign = (0..<6).map {
      HostGuestProcess(pid: 1000 + Int32($0), engine: "qemu", memoryGB: 4, directory: "/x/\($0)")
    }
    let gate = StartGate(hostMemory: Self.reader(availableGB: 30, guests: foreign))
    await #expect {
      _ = try await gate.admit(StartGateTests.linux("a", 5), running: { .empty }, host: Self.host)
    } throws: { error in
      Self.refusal(error)?.data["hostGuests"] == .number(6)
        && Self.refusal(error)?.data["freeGB"] == .number(8)
    }
    await gate.release(
      try await gate.admit(StartGateTests.linux("a", 4), running: { .empty }, host: Self.host))
  }

  @Test func ownGuestsAreNotCountedTwice() {
    let own = Inventory(guests: [
      Inventory.Guest(id: "a", profile: .qemuHVF, os: .linux, memoryGB: 4, pid: 1),
      Inventory.Guest(id: "b", profile: .qemuHVF, os: .linux, memoryGB: 4, directory: "/h/vms/b"),
    ])
    let processes = [
      HostGuestProcess(pid: 1, engine: "qemu", memoryGB: 4, directory: "/h/vms/a"),
      HostGuestProcess(pid: 2, engine: "qemu", memoryGB: 4, directory: "/h/vms/b/"),
      HostGuestProcess(pid: 3, engine: "vz", memoryGB: 8, directory: "/other/vms/m", os: .macos),
      HostGuestProcess(pid: 4, engine: "qemu", memoryGB: 2.5, directory: "/h/vms/new"),
    ]
    let starting = Inventory.Guest(
      id: "new", profile: .qemuHVF, os: .linux, memoryGB: 4, directory: "/h/vms/new")
    let all = own.addingHostGuests(processes, excluding: starting)
    #expect(all.guests.count == 3)
    #expect(all.memoryGB == 16)
    #expect(all.macOSGuests == 1)
  }

  @Test func foreignMacOSGuestsCountAgainstTheMacOSLimit() async throws {
    let macs = (0..<2).map {
      HostGuestProcess(pid: 50 + Int32($0), engine: "vz", memoryGB: 8, os: .macos)
    }
    let gate = StartGate(hostMemory: Self.reader(availableGB: 30, guests: macs))
    await #expect {
      _ = try await gate.admit(StartGateTests.macos("m"), running: { .empty }, host: Self.host)
    } throws: { ($0 as? VMLabError)?.code == .limitMacOSGuests }
  }

  @Test func theEscapeHatchSkipsPressureButKeepsTheBudget() async throws {
    var hatch = Self.reader(.critical, availableGB: 1)
    hatch.ignorePressure = true
    let gate = StartGate(hostMemory: hatch)
    await gate.release(
      try await gate.admit(StartGateTests.linux("a", 4), running: { .empty }, host: Self.host))
    await #expect {
      _ = try await gate.admit(StartGateTests.linux("a", 29), running: { .empty }, host: Self.host)
    } throws: { Self.refusal($0)?.data["freeGB"] == .number(32) }

    let home = try CrossProcessTests.home()
    #expect(!HostMemoryGuard.ignoresPressure(home: home, environment: [:]))
    #expect(
      HostMemoryGuard.ignoresPressure(
        home: home, environment: ["VMLAB_IGNORE_MEMORY_PRESSURE": "1"]))
    #expect(
      !HostMemoryGuard.ignoresPressure(
        home: home, environment: ["VMLAB_IGNORE_MEMORY_PRESSURE": "0"]))
    try Data(#"{"ignoreMemoryPressure": true}"#.utf8).write(to: VMLabConfig.url(home: home))
    #expect(HostMemoryGuard.ignoresPressure(home: home, environment: [:]))
    #expect(HostMemoryGuard.live(home: home, environment: [:]).ignorePressure)
  }

  @Test func theCrossProcessGateAppliesTheSameChecks() async throws {
    let home = try CrossProcessTests.home()
    let warn = FileStartGate(home: home, hostMemory: Self.reader(.warn))
    await #expect {
      _ = try await warn.admit(StartGateTests.linux("a", 4), running: { .empty }, host: Self.host)
    } throws: { Self.refusal($0)?.data["pressureLevel"] == .string("warn") }
    let a = FileStartGate(home: home, hostMemory: Self.reader(availableGB: 12))
    let b = FileStartGate(home: home, hostMemory: Self.reader(availableGB: 12))
    let held = try await a.admit(StartGateTests.linux("a", 4), running: { .empty }, host: Self.host)
    // 12 GB available less a's 4 GB in flight: 8 GB, short of 5 + 4.
    await #expect {
      _ = try await b.admit(StartGateTests.linux("b", 5), running: { .empty }, host: Self.host)
    } throws: { Self.refusal($0)?.data["availableGB"] == .number(8) }
    await b.release(
      try await b.admit(StartGateTests.linux("b", 4), running: { .empty }, host: Self.host))
    await a.release(held)
  }

  @Test func fleetsCheckTheHostForAllMembersAtOnce() throws {
    let plan = FleetsTests.plan
    let host = FleetsTests.host()
    try FleetPlanning.checkBudget(
      plan: plan, count: 3, running: .empty, host: host, limits: .defaults,
      hostMemory: Self.reader(availableGB: 16))
    #expect {
      try FleetPlanning.checkBudget(
        plan: plan, count: 4, running: .empty, host: host, limits: .defaults,
        hostMemory: Self.reader(availableGB: 16))
    } throws: { error in
      Self.refusal(error)?.data["requestedGB"] == .number(16)
        && Self.refusal(error)?.data["count"] == .number(4)
    }
    #expect {
      try FleetPlanning.checkBudget(
        plan: plan, count: 1, running: .empty, host: host, limits: .defaults,
        hostMemory: Self.reader(.critical))
    } throws: { Self.refusal($0)?.data["pressureLevel"] == .string("critical") }
  }

  @Test func recognizersFindGuestProcesses() {
    let recognizers = GuestProcessRecognizers([
      GuestProcessRecognizer(
        engine: "fake", matchesExecutable: { $0.hasSuffix("/fake-engine") },
        recognize: { process in
          process.arguments.first == "guest"
            ? HostGuestProcess(pid: process.pid, engine: "fake", memoryGB: 2) : nil
        })
    ])
    #expect(recognizers.wants("/opt/fake-engine"))
    #expect(!recognizers.wants("/bin/zsh"))
    let found = recognizers.guests(in: [
      HostProcessInfo(pid: 7, executable: "/opt/fake-engine", arguments: ["guest"]),
      HostProcessInfo(pid: 8, executable: "/opt/fake-engine", arguments: ["probe"]),
      HostProcessInfo(pid: 9, executable: "/bin/zsh", arguments: ["guest"]),
    ])
    #expect(found == [HostGuestProcess(pid: 7, engine: "fake", memoryGB: 2)])
  }

  @Test func procArgsParseIntoArguments() {
    var bytes: [UInt8] = []
    withUnsafeBytes(of: Int32(3)) { bytes += $0 }
    bytes += Array("/usr/bin/qemu".utf8) + [0, 0, 0, 0]
    for word in ["qemu", "-m", "4096M", "HOME=/x"] { bytes += Array(word.utf8) + [0] }
    #expect(HostProcesses.parseProcArgs(bytes) == ["-m", "4096M"])
    #expect(HostProcesses.parseProcArgs([1]) == nil)
  }

  /// Reading every host process's arguments takes seconds of CPU in a debug build: it runs on a
  /// thread of its own, so the cooperative pool stays free for the rest of the suite.
  @Test func theLiveReaderAnswersOnThisHost() async {
    let (snapshot, me) = await OffPool.run {
      let snapshot = LiveHostMemory(recognizers: GuestProcessRecognizers()).snapshot()
      // This test process is listed with its own arguments.
      let me = HostProcesses.list { _ in true }.first { $0.pid == getpid() }
      return (snapshot, me)
    }
    #expect([1, 2, 4].contains(snapshot.pressure.rawValue))
    #expect(snapshot.availableGB > 0)
    #expect(snapshot.guests.isEmpty)
    #expect(me != nil)
  }

  @Test func pressureNames() {
    #expect(MemoryPressure.normal.name == "normal" && !MemoryPressure.normal.isElevated)
    #expect(MemoryPressure.warn.isElevated && MemoryPressure.critical.name == "critical")
    #expect(MemoryPressure(rawValue: 8).name == "level 8")
  }
}
