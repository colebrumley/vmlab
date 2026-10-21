import Foundation
import Testing
import VMLabCore

@Suite struct CapabilitiesTests {
  static let repoRoot = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// REQUIREMENTS.md Appendix B, read from the document itself so drift fails `check.sh`. By C7
  /// the code is the authority: when these tests fail because the matrix changed on purpose, fix
  /// the appendix in the same commit.
  static let appendixB: String = {
    let url = repoRoot.appending(path: "REQUIREMENTS.md")
    guard let text = try? String(contentsOf: url, encoding: .utf8),
      let start = text.range(of: "\n## Appendix B")
    else { return "" }
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
  }()

  /// The matrix table of Appendix B: its header, separator and rows.
  static var table: [Substring] {
    appendixB.split(separator: "\n").drop { !$0.hasPrefix("| Feature |") }.prefix {
      $0.hasPrefix("|")
    }
    .map { $0 }
  }

  /// The committed slow-probe snapshot of the development host (`docs/dev-host-facts.json`).
  static func devHostProbes() throws -> SlowProbes {
    let data = try Data(contentsOf: repoRoot.appending(path: "docs/dev-host-facts.json"))
    return try SlowProbes.decoder.decode(SlowProbes.self, from: data)
  }

  static var rows: [(String, [String])] {
    table.dropFirst(2).map { line in
      let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
      return (cells[0], Array(cells[1...]))
    }
  }

  static var featureRows: [(String, [String])] { rows.filter { $0.0.hasPrefix("`") } }

  static func host(probes result: ProbeResult) -> HostFacts {
    var probes = SlowProbes()
    for probe in SlowProbe.allCases { probes[probe] = ProbeRecord(result: result) }
    return HostFacts(
      osVersion: "26.6.2", chip: .init(model: "Apple M1 Max", generation: 1), memoryGB: 32,
      freeMemoryGB: 10, freeDiskGB: 200, isRoot: false,
      qemu: .init(present: true, version: "11.1.2", accelerators: ["hvf", "tcg"]),
      tart: .absent, rosettaInstalled: true, nestedSupported: false, runnerSigned: true,
      probes: probes)
  }

  /// The resolved matrix as one line per feature, Y or N per profile in Appendix B column order.
  static func snapshot(_ host: HostFacts) -> String {
    let matrix = Profile.allCases.map { Capabilities.capabilities(of: $0, host: host) }
    return Feature.allCases.map { feature in
      feature.rawValue + " "
        + matrix.map { $0[feature] == .yes ? "Y" : "N" }.joined(separator: " ")
    }.joined(separator: "\n")
  }

  @Test func appendixBHeaderNamesTheProfilesInOrder() throws {
    let header = try #require(Self.table.first)
    let names = header.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
      .dropFirst().map { $0.split(separator: " ").first.map(String.init) ?? "" }
    #expect(names == Profile.allCases.map(\.rawValue))
  }

  @Test func everyFeatureRowOfAppendixBIsInTheDocument() {
    #expect(
      Self.featureRows.map { String($0.0.dropFirst().dropLast()) }
        == Feature.allCases.map(\.rawValue))
  }

  /// One assertion per cell of Appendix B: kind (Y, N, C, ?), the facts or probes it names, the
  /// item that verifies a `?`, and the note in parentheses.
  @Test(arguments: featureRows.map(\.0))
  func codeAgreesWithAppendixB(row name: String) throws {
    let cells = try #require(Self.featureRows.first { $0.0 == name }?.1)
    let feature = try #require(Feature(rawValue: String(name.dropFirst().dropLast())))
    var previous: Capabilities.Entry?
    for (profile, cell) in zip(Profile.allCases, cells) {
      let entry = Capabilities.entry(feature, on: profile)
      let context = Comment(rawValue: "\(feature.rawValue) on \(profile.rawValue): \(cell)")
      if cell == "C same" || cell == "Y (same)", let same = previous {
        #expect(entry == same, context)
        continue
      }
      let note = cell.firstRange(of: "(").map {
        String(cell[$0.upperBound...].dropLast())
      }
      switch cell.first {
      case "Y":
        #expect(entry.availability == .yes, context)
        #expect(entry.note == note, context)
      case "N":
        guard case .no(let reason) = entry.availability else {
          Issue.record(context)
          break
        }
        #expect(!reason.isEmpty, context)
        #expect(entry.note == note, context)
      case "C", "?":
        guard case .conditional(let condition) = entry.availability else {
          Issue.record(context)
          break
        }
        let names = cell.split(separator: "`").enumerated().filter { $0.offset % 2 == 1 }
          .map { String($0.element) }
        #expect(condition.names == names, context)
        #expect(entry.verifiedBy == (cell.first == "?" ? note : nil), context)
      default:
        Issue.record(context)
      }
      previous = entry
    }
  }

  @Test func guestAndTierRowsAgreeWithAppendixB() throws {
    let rows = Dictionary(uniqueKeysWithValues: Self.rows)
    let os = try #require(rows["Guest OS"])
    #expect(
      Profile.allCases.map { Capabilities.guestOS(of: $0) == .macos ? "macOS" : "Linux" } == os)
    let arch = try #require(rows["Arch"])
    for (profile, archs) in zip(Profile.allCases, arch) {
      for name in archs.split(separator: ", ") {
        let guest = GuestSpec(
          os: Capabilities.guestOS(of: profile), arch: .init(rawValue: String(name)))
        #expect(Capabilities.supports(guest, on: profile), "\(name) on \(profile.rawValue)")
      }
    }
    #expect(rows["Performance tier (1 best)"] == Profile.allCases.map { "\($0.performanceTier)" })
    #expect(rows["Energy tier (1 best)"] == Profile.allCases.map { "\($0.energyTier)" })
    #expect(rows["Startup tier (1 best)"] == Profile.allCases.map { "\($0.startupTier)" })
  }

  /// R-1103: every slow probe the matrix names has run on the development host, so the
  /// generated matrix's verified column shows no `unknown`.
  @Test func devHostHasAnsweredEveryProbe() throws {
    let probes = try Self.devHostProbes()
    for probe in SlowProbe.allCases {
      #expect(probes[probe].result != .unknown, "\(probe.rawValue) is unknown in the snapshot")
    }
    for feature in Feature.allCases {
      #expect(!FeatureDocs.verified(feature, probes: probes).contains("unknown"), "\(feature)")
    }
  }

  /// Appendix B lists what the development host recorded, one line per probe-gated feature,
  /// exactly as the verified column of `docs/FEATURES.md` renders it from the snapshot.
  @Test func appendixBRecordsTheDevHostProbes() throws {
    let probes = try Self.devHostProbes()
    let expected = Feature.allCases.compactMap { feature -> String? in
      let verified = FeatureDocs.verified(feature, probes: probes)
      return verified.isEmpty ? nil : "- `\(feature.rawValue)`: \(verified)"
    }
    let listed = Self.appendixB.split(separator: "\n").map(String.init)
      .filter { $0.hasPrefix("- `") }
    #expect(listed == expected)
  }

  @Test func guestFilter() {
    let linuxArm = GuestSpec(os: .linux, arch: .arm64)
    let linuxX86 = GuestSpec(os: .linux, arch: .x86_64)
    let mac = GuestSpec(os: .macos, arch: .arm64)
    #expect(
      Profile.allCases.filter { Capabilities.supports(linuxArm, on: $0) }
        == [.vzLinux, .qemuHVF, .qemuTCG])
    #expect(Profile.allCases.filter { Capabilities.supports(linuxX86, on: $0) } == [.qemuTCG])
    #expect(Profile.allCases.filter { Capabilities.supports(mac, on: $0) } == [.vzMacOS])
    let macX86 = GuestSpec(os: .macos, arch: .x86_64)
    #expect(Profile.allCases.filter { Capabilities.supports(macX86, on: $0) }.isEmpty)
  }

  /// Fixture: M1, not root, Rosetta installed, every slow probe `yes`.
  @Test func snapshotAllProbesYes() {
    #expect(
      Self.snapshot(Self.host(probes: .yes)) == """
        exec_ssh Y Y Y Y
        exec_agent N N Y Y
        gui Y Y Y Y
        gui_preboot N N Y Y
        gui_desktop Y Y Y Y
        gui_accel Y Y N N
        serial N Y Y Y
        gdb N N Y Y
        introspection N N Y Y
        memory_dump N N Y Y
        direct_kernel_boot N Y Y Y
        custom_firmware N N Y Y
        custom_devices N N Y Y
        halt_at_start N N Y Y
        checkpoint_disk Y Y Y Y
        checkpoint_live Y Y Y Y
        pause Y Y Y Y
        net_nat Y Y Y Y
        net_fast Y Y Y Y
        net_segment Y Y Y Y
        net_port_forward Y Y Y Y
        net_none Y Y Y Y
        rosetta N Y N N
        nested_virt N N N Y
        shared_dir Y Y Y Y
        cloud_init N Y Y Y
        many_guests N Y Y Y
        cpu_emulation N N N Y
        """)
  }

  /// The same host with every slow probe `unknown`: each feature a probe gates becomes `no`.
  @Test func snapshotAllProbesUnknown() {
    #expect(
      Self.snapshot(Self.host(probes: .unknown)) == """
        exec_ssh Y Y Y Y
        exec_agent N N Y Y
        gui Y Y Y Y
        gui_preboot N N Y Y
        gui_desktop Y Y Y Y
        gui_accel Y Y N N
        serial N Y Y Y
        gdb N N N Y
        introspection N N Y Y
        memory_dump N N Y Y
        direct_kernel_boot N Y Y Y
        custom_firmware N N Y Y
        custom_devices N N Y Y
        halt_at_start N N Y Y
        checkpoint_disk Y Y Y Y
        checkpoint_live N N N Y
        pause Y Y Y Y
        net_nat Y Y Y Y
        net_fast Y Y N N
        net_segment Y Y Y Y
        net_port_forward Y Y Y Y
        net_none Y Y Y Y
        rosetta N Y N N
        nested_virt N N N Y
        shared_dir Y Y Y Y
        cloud_init N Y Y Y
        many_guests N Y Y Y
        cpu_emulation N N N Y
        """)
  }

  /// R-101's open assertion: an `unknown` probe makes the dependent feature unavailable, names
  /// the probe in the reason, is reported unverified, and `allowUnverified` treats it as yes.
  @Test(arguments: [
    (Feature.gdb, Profile.qemuHVF, SlowProbe.qemuHVFGDB),
    (.checkpointLive, .qemuHVF, .qemuHVFLiveSnapshot),
    (.checkpointLive, .vzLinux, .vzLinuxLiveSnapshot),
    (.checkpointLive, .vzMacOS, .vzMacOSLiveSnapshot),
    (.netFast, .qemuHVF, .qemuVmnet),
    (.netFast, .qemuTCG, .qemuVmnet),
  ])
  func unknownProbeMakesFeatureUnavailable(feature: Feature, profile: Profile, probe: SlowProbe) {
    var host = Self.host(probes: .yes)
    #expect(Capabilities.capabilities(of: profile, host: host)[feature] == .yes)
    #expect(Capabilities.unverifiedProbes(feature, on: profile, host: host).isEmpty)

    host.probes[probe] = .unknown
    guard case .no(let reason) = Capabilities.capabilities(of: profile, host: host)[feature] else {
      Issue.record("\(feature.rawValue) on \(profile.rawValue) should be no")
      return
    }
    #expect(reason.contains(probe.rawValue))
    #expect(Capabilities.unverifiedProbes(feature, on: profile, host: host) == [probe])
    #expect(
      Capabilities.capabilities(of: profile, host: host, allowUnverified: true)[feature] == .yes)

    host.probes[probe] = ProbeRecord(result: .no)
    #expect(Capabilities.capabilities(of: profile, host: host)[feature] != .yes)
    #expect(
      Capabilities.capabilities(of: profile, host: host, allowUnverified: true)[feature] != .yes)
    #expect(Capabilities.unverifiedProbes(feature, on: profile, host: host).isEmpty)
  }

  @Test func fastFactsResolveConditions() {
    var host = Self.host(probes: .unknown)
    #expect(capabilities(of: .qemuHVF, host: host)[.netFast] != .yes)
    host.isRoot = true
    #expect(capabilities(of: .qemuHVF, host: host)[.netFast] == .yes)

    host.rosettaInstalled = false
    #expect(capabilities(of: .vzLinux, host: host)[.rosetta] != .yes)
    host.rosettaInstalled = true
    #expect(capabilities(of: .vzLinux, host: host)[.rosetta] == .yes)

    #expect(capabilities(of: .vzLinux, host: host)[.nestedVirt] != .yes)
    host.nestedSupported = true
    #expect(capabilities(of: .vzLinux, host: host)[.nestedVirt] == .yes)
  }

  /// R-309: a `no` from `qemu_vmnet` says what vmnet needs, after the root clause.
  @Test func vmnetNoSaysWhatItNeeds() {
    var host = Self.host(probes: .yes)
    host.probes[.qemuVmnet] = ProbeRecord(result: .no)
    guard case .no(let reason) = capabilities(of: .qemuHVF, host: host)[.netFast] else {
      Issue.record("net_fast is not no without root and vmnet")
      return
    }
    #expect(reason.hasPrefix("vmlab is not running as root; and "))
    #expect(reason.contains("com.apple.vm.networking entitlement"))
  }

  @Test func everyNoHasAReason() {
    let host = Self.host(probes: .unknown)
    for profile in Profile.allCases {
      for (feature, availability) in Capabilities.capabilities(of: profile, host: host) {
        if case .no(let reason) = availability {
          #expect(!reason.isEmpty, "\(feature.rawValue) on \(profile.rawValue)")
        }
        #expect(availability == .yes || !availability.isYes)
        if case .conditional = availability { Issue.record("unresolved \(feature.rawValue)") }
      }
    }
  }

  /// R-604: firmware and device customisation stay `no` under VZ, with one reason.
  @Test func vzRefusesCustomFirmwareAndDevices() {
    for profile in [Profile.vzLinux, .vzMacOS] {
      for feature in [Feature.customFirmware, .customDevices] {
        #expect(
          Capabilities.entry(feature, on: profile).availability
            == .no("Virtualization.framework boots only Apple EFI or a Linux kernel"))
      }
    }
    #expect(Capabilities.entry(.directKernelBoot, on: .vzLinux).availability == .yes)
  }

  /// R-1204: `cpu_emulation` is `qemu-tcg` alone; every other engine runs the CPU natively.
  @Test func cpuEmulationIsTCGOnly() {
    for profile in Profile.allCases {
      #expect(
        Capabilities.entry(.cpuEmulation, on: profile).availability
          == (profile == .qemuTCG ? .yes : .no("the engine runs the guest CPU natively")))
    }
    #expect(Feature.cpuEmulation.kind == .compute)
  }

  /// R-609: `nested_virt` on vz-linux is `no` with the reason for an M1 fact set and `yes` for an
  /// M3 on macOS 15.
  @Test func nestedVirtFollowsTheChip() {
    var host = Self.host(probes: .unknown)
    host.chip = .init(model: "Apple M1 Max", generation: 1)
    host.osVersion = "26.6.2"
    host.nestedSupported = HostProbe.nestedSupported(chip: host.chip, osVersion: host.osVersion)
    guard case .no(let reason) = capabilities(of: .vzLinux, host: host)[.nestedVirt] else {
      Issue.record("nested_virt is not no on an M1")
      return
    }
    #expect(reason.contains("needs an M3 or newer and macOS 15"))
    host.chip = .init(model: "Apple M3 Pro", generation: 3)
    host.osVersion = "15.1"
    host.nestedSupported = HostProbe.nestedSupported(chip: host.chip, osVersion: host.osVersion)
    #expect(capabilities(of: .vzLinux, host: host)[.nestedVirt] == .yes)
  }
}
