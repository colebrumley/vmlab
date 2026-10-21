import Foundation

/// A host fact or slow probe that a conditional matrix entry depends on (Appendix B, Appendix E).
public indirect enum Condition: Sendable, Hashable {
  /// The server runs as root (`isRoot`).
  case root
  /// Rosetta for Linux is installed on the host (`rosettaInstalled`).
  case rosettaInstalled
  /// Virtualization.framework supports nested virtualization here (`nestedSupported`: M3 or newer,
  /// macOS 15 or newer).
  case nestedSupported
  /// A slow probe persisted in `host-facts.json` answered `yes`.
  case probe(SlowProbe)
  /// Any one of the conditions holds.
  case anyOf([Condition])

  /// The fact or probe name as Appendix B and Appendix E write it (`root`, `qemu_vmnet`).
  public var name: String {
    switch self {
    case .root: "root"
    case .rosettaInstalled: "rosetta_installed"
    case .nestedSupported: "nested_supported"
    case .probe(let probe): probe.rawValue
    case .anyOf(let conditions): conditions.map(\.name).joined(separator: " or ")
    }
  }

  /// Every leaf condition's name, in order.
  public var names: [String] {
    switch self {
    case .anyOf(let conditions): conditions.flatMap(\.names)
    default: [name]
    }
  }

  /// The slow probes this condition reads, in order.
  public var probes: [SlowProbe] {
    switch self {
    case .probe(let probe): [probe]
    case .anyOf(let conditions): conditions.flatMap(\.probes)
    default: []
    }
  }

  /// Whether the condition holds on `host`. An `unknown` probe counts as `no` unless
  /// `allowUnverified` is set (Appendix I step 2).
  public func holds(on host: HostFacts, allowUnverified: Bool = false) -> Bool {
    switch self {
    case .root: host.isRoot
    case .rosettaInstalled: host.rosettaInstalled
    case .nestedSupported: host.nestedSupported
    case .probe(let probe):
      host.probe(probe).countsAsYes || (allowUnverified && host.probe(probe).isUnverified)
    case .anyOf(let conditions):
      conditions.contains { $0.holds(on: host, allowUnverified: allowUnverified) }
    }
  }

  /// Why the condition fails on `host`, for the model: one clause per leaf that is not met.
  public func reasonUnmet(on host: HostFacts) -> String {
    switch self {
    case .root: "vmlab is not running as root"
    case .rosettaInstalled:
      "Rosetta for Linux is not installed on the host (softwareupdate --install-rosetta)"
    case .nestedSupported:
      "nested virtualization needs an M3 or newer and macOS 15 (host: \(host.chip.model), macOS \(host.osVersion))"
    case .probe(let probe):
      switch host.probe(probe) {
      case .unknown: "probe \(probe.rawValue) has not been verified on this host"
      case .no: probe.noReason ?? "probe \(probe.rawValue) answered no on this host"
      case .yes: "probe \(probe.rawValue) answered yes"
      }
    case .anyOf(let conditions):
      conditions.filter { !$0.holds(on: host) }.map { $0.reasonUnmet(on: host) }
        .joined(separator: "; and ")
    }
  }
}

extension SlowProbe {
  /// What a refusal says when this probe answered `no`, for probes with more to say than that.
  public var noReason: String? {
    switch self {
    case .qemuHVFGDB:
      "GDB under HVF unsupported by this QEMU (probe qemu_hvf_gdb answered no); use arch x86_64, "
        + "or run the arm64 guest under qemu-tcg (emulated, slow)"
    case .qemuVmnet:
      "QEMU cannot create a vmnet interface without root or Apple's com.apple.vm.networking "
        + "entitlement (probe qemu_vmnet answered no)"
    default: nil
    }
  }
}

/// One cell of the capability matrix. `conditional` is resolved to yes or no by host facts.
public enum Availability: Sendable, Hashable {
  case yes
  case no(String)
  case conditional(Condition)

  public var isYes: Bool { self == .yes }

  /// This entry with its condition resolved against `host`: `.yes` or `.no(reason)`.
  public func resolved(on host: HostFacts, allowUnverified: Bool = false) -> Availability {
    switch self {
    case .yes, .no: self
    case .conditional(let condition):
      condition.holds(on: host, allowUnverified: allowUnverified)
        ? .yes : .no(condition.reasonUnmet(on: host))
    }
  }
}

/// The capability matrix (Appendix B). By constraint C7 this file is the authority: when the
/// appendix disagrees with it, the appendix is fixed.
public enum Capabilities {
  /// One cell: its availability, a short note for the generated table, and for a cell gated on a
  /// slow probe (a `[VERIFY]` row of Appendix B), the backlog item that runs it.
  public struct Entry: Sendable, Hashable {
    public var availability: Availability
    public var note: String?
    public var verifiedBy: String?

    public init(_ availability: Availability, note: String? = nil, verifiedBy: String? = nil) {
      self.availability = availability
      self.note = note
      self.verifiedBy = verifiedBy
    }
  }

  private static func y(_ note: String? = nil) -> Entry { Entry(.yes, note: note) }
  private static func n(_ reason: String, note: String? = nil) -> Entry {
    Entry(.no(reason), note: note)
  }
  private static func c(_ condition: Condition, verifiedBy: String? = nil) -> Entry {
    Entry(.conditional(condition), verifiedBy: verifiedBy)
  }

  private static let vzNoQEMU = "Virtualization.framework has no public API for it"
  private static let noVZGDB = "Virtualization.framework exposes no public GDB stub"
  /// R-604: the reason for both `custom_firmware` and `custom_devices` under VZ.
  private static let vzBootsOnlyEFIOrKernel =
    "Virtualization.framework boots only Apple EFI or a Linux kernel"
  private static let vzNoFirmware = vzBootsOnlyEFIOrKernel
  private static let vzFixedDevices = vzBootsOnlyEFIOrKernel
  /// R-1204: why only `qemu-tcg` has `cpu_emulation`.
  private static let nativeCPU = "the engine runs the guest CPU natively"

  /// The unresolved matrix entry for `feature` on `profile`.
  public static func entry(_ feature: Feature, on profile: Profile) -> Entry {
    switch (feature, profile) {
    case (.execSSH, _): y()

    case (.execAgent, .vzMacOS), (.execAgent, .vzLinux):
      n("no host-side agent channel for VZ guests in v1; use exec_ssh")
    case (.execAgent, .qemuHVF): y("qemu-ga")
    case (.execAgent, .qemuTCG): y()

    case (.gui, .vzMacOS): y("guest Screen Sharing")
    case (.gui, .vzLinux): y("in-guest VNC")
    case (.gui, .qemuHVF): y("QEMU VNC")
    case (.gui, .qemuTCG): y()

    case (.guiPreboot, .vzMacOS), (.guiPreboot, .vzLinux):
      n("the VZ display is reached through an in-guest VNC server, which needs a running OS")
    case (.guiPreboot, _): y()

    case (.guiDesktop, .vzMacOS): y("built in")
    case (.guiDesktop, .vzLinux), (.guiDesktop, .qemuHVF): y("R-504")
    case (.guiDesktop, .qemuTCG): y()

    case (.guiAccel, .vzMacOS), (.guiAccel, .vzLinux): y()
    case (.guiAccel, _): n("QEMU guests get no GPU on this host in v1")

    case (.serial, .vzMacOS): n("macOS guests have no serial console under VZ")
    case (.serial, _): y()

    case (.gdb, .vzMacOS), (.gdb, .vzLinux): n(noVZGDB)
    case (.gdb, .qemuHVF): c(.probe(.qemuHVFGDB), verifiedBy: "R-702")
    case (.gdb, .qemuTCG): y()

    case (.introspection, .vzMacOS), (.introspection, .vzLinux): n(vzNoQEMU)
    case (.introspection, _): y()

    case (.memoryDump, .vzMacOS), (.memoryDump, .vzLinux): n(vzNoQEMU)
    case (.memoryDump, _): y()

    case (.directKernelBoot, .vzMacOS): n("macOS guests boot only from their own disk")
    case (.directKernelBoot, _): y()

    case (.customFirmware, .vzMacOS), (.customFirmware, .vzLinux): n(vzNoFirmware)
    case (.customFirmware, _): y()

    case (.customDevices, .vzMacOS), (.customDevices, .vzLinux): n(vzFixedDevices)
    case (.customDevices, _): y()

    case (.haltAtStart, .vzMacOS), (.haltAtStart, .vzLinux): n(noVZGDB)
    case (.haltAtStart, _): y()

    case (.checkpointDisk, _): y()

    case (.checkpointLive, .vzMacOS):
      c(.probe(.vzMacOSLiveSnapshot), verifiedBy: "R-608")
    case (.checkpointLive, .vzLinux):
      c(.probe(.vzLinuxLiveSnapshot), verifiedBy: "R-608")
    case (.checkpointLive, .qemuHVF):
      c(.probe(.qemuHVFLiveSnapshot), verifiedBy: "R-307")
    case (.checkpointLive, .qemuTCG): y()

    case (.pause, _): y()
    case (.netNAT, _): y()

    case (.netFast, .vzMacOS), (.netFast, .vzLinux): y()
    case (.netFast, _): c(.anyOf([.root, .probe(.qemuVmnet)]))

    case (.netSegment, .vzMacOS): y("static, R-901")
    case (.netSegment, .vzLinux): y("socketpair to vmlab-switch")
    // R-901 [VERIFY]: Homebrew QEMU 11.1.2 attaches `-netdev dgram` unix paths to vmlab-switch
    // (two guests pinged), so the mcast fallback was not built.
    case (.netSegment, _): y("-netdev dgram unix, verified on QEMU 11.1")

    case (.netPortForward, .vzMacOS), (.netPortForward, .vzLinux): y("host-reachable address")
    case (.netPortForward, _): y("hostfwd")

    case (.netNone, _): y()

    case (.rosetta, .vzLinux): c(.rosettaInstalled)
    case (.rosetta, _): n("Rosetta for Linux is offered only to Linux guests under VZ")

    case (.nestedVirt, .vzLinux): c(.nestedSupported)
    case (.nestedVirt, .qemuTCG): y("slow")
    case (.nestedVirt, .vzMacOS): n("VZ offers nested virtualization only to Linux guests")
    case (.nestedVirt, .qemuHVF): n("HVF does not expose nested virtualization to QEMU guests")

    case (.sharedDir, .vzMacOS), (.sharedDir, .vzLinux): y("virtiofs")
    case (.sharedDir, _): y("9p")

    case (.cloudInit, .vzMacOS): n("cloud-init is for Linux guests")
    case (.cloudInit, _): y()

    case (.manyGuests, .vzMacOS):
      n("macOS allows at most two macOS guests at once", note: "limit 2")
    case (.manyGuests, _): y()

    case (.cpuEmulation, .qemuTCG): y()
    case (.cpuEmulation, _): n(nativeCPU)
    }
  }

  /// The availability of every feature on `profile`, resolved against `host`. An `unknown` slow
  /// probe makes the feature it gates `no` unless `allowUnverified` is set.
  public static func capabilities(
    of profile: Profile, host: HostFacts, allowUnverified: Bool = false
  ) -> [Feature: Availability] {
    Dictionary(
      uniqueKeysWithValues: Feature.allCases.map {
        (
          $0,
          entry($0, on: profile).availability.resolved(on: host, allowUnverified: allowUnverified)
        )
      })
  }

  /// The slow probes behind `feature` on `profile` that are `unknown` on `host`: what `vm_plan`
  /// reports as `unverified`.
  public static func unverifiedProbes(
    _ feature: Feature, on profile: Profile, host: HostFacts
  ) -> [SlowProbe] {
    guard case .conditional(let condition) = entry(feature, on: profile).availability else {
      return []
    }
    return condition.probes.filter { host.probe($0).isUnverified }
  }

  /// The guest OS a profile runs (Appendix B).
  public static func guestOS(of profile: Profile) -> GuestSpec.OS {
    profile == .vzMacOS ? .macos : .linux
  }

  /// Whether `profile` can run `guest` (Appendix B's guest OS and arch rows; Appendix I step 3).
  public static func supports(_ guest: GuestSpec, on profile: Profile) -> Bool {
    guard guest.os == guestOS(of: profile) else { return false }
    return profile == .qemuTCG || guest.arch == .arm64
  }
}

/// `capabilities(of:host:)` as a free function, the spelling R-102 names.
public func capabilities(of profile: Profile, host: HostFacts) -> [Feature: Availability] {
  Capabilities.capabilities(of: profile, host: host)
}
