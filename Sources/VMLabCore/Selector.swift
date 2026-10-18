/// What the selector chose for a request (Appendix I step 8; Appendix C `vm_plan`).
public struct Plan: Codable, Sendable, Hashable {
  public var profile: Profile
  public var guest: GuestSpec
  /// The request's resources with every Appendix G default filled in.
  public var resources: ResourceSpec
  /// Every required feature plus every other feature that is `yes` for the profile on this host,
  /// in catalogue order.
  public var features: [Feature]
  /// The features the request asked for (required, implied or preferred) that the profile grants,
  /// in catalogue order. `features` also holds every other `yes`; what is provisioned for the guest
  /// (the in-guest desktop, R-504; the VZ display, R-503) follows this list. Empty in plans stored
  /// before it existed.
  public var requested: [Feature]
  /// Preferred features the profile does not provide.
  public var preferredDenied: [Feature]
  /// Requested features whose answer on this host rests on a slow probe that is still `unknown`.
  public var unverified: [Feature]
  /// Whether `unknown` probes were treated as `yes`.
  public var allowUnverified: Bool
  public var estimatedStartupSeconds: Int
  public var notes: [String]

  public init(
    profile: Profile, guest: GuestSpec, resources: ResourceSpec, features: [Feature],
    requested: [Feature] = [], preferredDenied: [Feature] = [], unverified: [Feature] = [],
    allowUnverified: Bool = false, estimatedStartupSeconds: Int, notes: [String] = []
  ) {
    self.profile = profile
    self.guest = guest
    self.resources = resources
    self.features = features
    self.requested = requested
    self.preferredDenied = preferredDenied
    self.unverified = unverified
    self.allowUnverified = allowUnverified
    self.estimatedStartupSeconds = estimatedStartupSeconds
    self.notes = notes
  }

  public func grants(_ feature: Feature) -> Bool { features.contains(feature) }

  /// Whether the request asked for `feature` and the profile grants it.
  public func requests(_ feature: Feature) -> Bool { requested.contains(feature) }

  enum CodingKeys: String, CodingKey {
    case profile, guest, resources, features, requested, preferredDenied, unverified
    case allowUnverified, estimatedStartupSeconds, notes
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    profile = try c.decode(Profile.self, forKey: .profile)
    guest = try c.decode(GuestSpec.self, forKey: .guest)
    resources = try c.decode(ResourceSpec.self, forKey: .resources)
    features = try c.decode([Feature].self, forKey: .features)
    requested = try c.decodeIfPresent([Feature].self, forKey: .requested) ?? []
    preferredDenied = try c.decodeIfPresent([Feature].self, forKey: .preferredDenied) ?? []
    unverified = try c.decodeIfPresent([Feature].self, forKey: .unverified) ?? []
    allowUnverified = try c.decodeIfPresent(Bool.self, forKey: .allowUnverified) ?? false
    estimatedStartupSeconds = try c.decode(Int.self, forKey: .estimatedStartupSeconds)
    notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
  }
}

/// Why no profile can run a request (Appendix I steps 5 and 6). `error` is what the model sees.
public struct Unsatisfiable: Error, Sendable, Hashable {
  /// Dropping `drop` from the required features lets `profile` run the request.
  public struct Suggestion: Codable, Sendable, Hashable {
    public var drop: [Feature]
    public var profile: Profile

    public init(drop: [Feature], profile: Profile) {
      self.drop = drop
      self.profile = profile
    }
  }

  public var guest: GuestSpec
  /// For each required feature, the guest-compatible profiles it ruled out.
  public var eliminated: [Feature: [Profile]]
  /// Why each feature ruled out each profile (the matrix reason).
  public var reasons: [Feature: [Profile: String]]
  /// Smallest subsets of the required features whose removal leaves a profile, best first.
  public var suggestions: [Suggestion]
  /// Required features denied only because a slow probe is `unknown`, with those probes, when
  /// `allowUnverified` would have found a profile.
  public var unverified: [Feature: [SlowProbe]]
  /// The dynamic limit that refused the best profile that has every feature.
  public var limit: VMLabError?

  public init(
    guest: GuestSpec, eliminated: [Feature: [Profile]] = [:],
    reasons: [Feature: [Profile: String]] = [:], suggestions: [Suggestion] = [],
    unverified: [Feature: [SlowProbe]] = [:], limit: VMLabError? = nil
  ) {
    self.guest = guest
    self.eliminated = eliminated
    self.reasons = reasons
    self.suggestions = suggestions
    self.unverified = unverified
    self.limit = limit
  }

  /// `limit_macos_guests` or `limit_memory` when a limit refused; `unverified_capability` when an
  /// unverified probe alone stands in the way; `unsatisfiable` otherwise.
  public var error: VMLabError {
    if let limit { return limit }
    var data: [String: JSONValue] = [
      "eliminated": .object(
        Dictionary(
          uniqueKeysWithValues: eliminated.map { feature, profiles in
            (feature.rawValue, .array(profiles.map { .string($0.rawValue) }))
          })),
      "suggestions": .array(
        suggestions.map {
          .object([
            "drop": .array($0.drop.map { .string($0.rawValue) }),
            "profile": .string($0.profile.rawValue),
          ])
        }),
    ]
    if let (feature, probes) = unverified.min(by: { $0.key.rawValue < $1.key.rawValue }),
      let probe = probes.first
    {
      data["feature"] = .string(feature.rawValue)
      data["probe"] = .string(probe.rawValue)
      return VMLabError(
        code: .unverifiedCapability,
        message:
          "\(feature.rawValue) depends on probe \(probe.rawValue), which has not been verified "
          + "on this host",
        hint: "run host_doctor with probe: true, or set allowUnverified to try it anyway",
        data: data)
    }
    let message: String
    if eliminated.isEmpty {
      message = "No profile runs a \(guest.os.rawValue) \(guest.arch.rawValue) guest"
    } else {
      let clauses = eliminated.keys.sorted { $0.rawValue < $1.rawValue }.map { feature in
        let why = (eliminated[feature] ?? []).map { profile in
          "\(profile.rawValue): \(reasons[feature]?[profile] ?? "not available")"
        }
        return "\(feature.rawValue) (\(why.joined(separator: "; ")))"
      }
      message =
        "No profile provides every required feature on this host: "
        + clauses.joined(separator: ", ")
    }
    let hint =
      suggestions.first.map {
        "Drop \($0.drop.map(\.rawValue).joined(separator: " and ")) from require to get "
          + "\($0.profile.rawValue)."
      } ?? "Ask for a Linux guest, which more profiles run."
    return VMLabError(code: .unsatisfiable, message: message, hint: hint, data: data)
  }
}

/// The Appendix I selection algorithm. Pure: host facts and the running guests come in as values.
public enum ProfileSelector {
  public static func select(
    _ r: Requirements, host: HostFacts, running: Inventory, allowUnverified: Bool = false,
    limits: ResourceLimits = .defaults
  ) -> Result<Plan, Unsatisfiable> {
    // 1. Normalise: implied features become required; preferences already required are dropped.
    var required: [Feature] = []
    for feature in r.require + r.impliedFeatures.map(\.feature) where !required.contains(feature) {
      required.append(feature)
    }
    var preferred: [Feature] = []
    for feature in r.prefer where !required.contains(feature) && !preferred.contains(feature) {
      preferred.append(feature)
    }
    let resources = ResourceLimits.resolve(r.resources, for: r.guest.os)

    // 2-3. Host facts and the guest filter.
    let candidates = Profile.allCases.filter { Capabilities.supports(r.guest, on: $0) }
    let matrix = Dictionary(
      uniqueKeysWithValues: candidates.map {
        ($0, Capabilities.capabilities(of: $0, host: host, allowUnverified: allowUnverified))
      })
    func has(_ profile: Profile, _ feature: Feature) -> Bool {
      matrix[profile]?[feature] == .yes
    }
    // An emulated CPU is the last resort for a guest the host runs natively: preferences never
    // pull an arm64 guest onto qemu-tcg while a hardware-virtualized profile survives (the
    // Appendix I example `require [gdb], prefer [checkpoint_live]` lands on qemu-hvf).
    let emulationLast = r.guest.arch == .arm64
    func rankKey(_ p: Profile) -> [Int] {
      [
        emulationLast && p == .qemuTCG ? 1 : 0, -preferred.count(where: { has(p, $0) }),
        p.performanceTier, p.energyTier, p.startupTier,
        Profile.allCases.firstIndex(of: p)!,
      ]
    }
    func ranked(_ profiles: [Profile]) -> [Profile] {
      profiles.sorted { rankKey($0).lexicographicallyPrecedes(rankKey($1)) }
    }
    func survivors(_ features: [Feature]) -> [Profile] {
      ranked(candidates.filter { p in features.allSatisfy { has(p, $0) } })
    }

    // 4. Feature filter.
    var eliminated: [Feature: [Profile]] = [:]
    var reasons: [Feature: [Profile: String]] = [:]
    for feature in required {
      let gone = candidates.filter { !has($0, feature) }
      guard !gone.isEmpty else { continue }
      eliminated[feature] = gone
      for profile in gone {
        if case .no(let reason) = matrix[profile]?[feature] {
          reasons[feature, default: [:]][profile] = reason
        }
      }
    }
    let alive = survivors(required)

    // 5. Empty: suggestions, and whether an unverified probe alone is in the way.
    guard !alive.isEmpty else {
      var unverified: [Feature: [SlowProbe]] = [:]
      if !allowUnverified {
        let lenient = Profile.allCases.filter { Capabilities.supports(r.guest, on: $0) }.filter {
          p in
          let caps = Capabilities.capabilities(of: p, host: host, allowUnverified: true)
          return required.allSatisfy { caps[$0] == .yes }
        }
        if let best = ranked(lenient).first {
          for feature in required where !has(best, feature) {
            let probes = Capabilities.unverifiedProbes(feature, on: best, host: host)
            if !probes.isEmpty { unverified[feature] = probes }
          }
        }
      }
      return .failure(
        Unsatisfiable(
          guest: r.guest, eliminated: eliminated, reasons: reasons,
          suggestions: suggestions(required: required, survivors: survivors, rankKey: rankKey),
          unverified: unverified))
    }

    // 6-7. Dynamic limits over the survivors in rank order.
    var firstRefusal: VMLabError?
    var chosen: Profile?
    for profile in alive {
      do {
        try limits.check(
          profile: profile, memoryGB: resources.memoryGB ?? 0, running: running, host: host)
        chosen = profile
        break
      } catch {
        if firstRefusal == nil { firstRefusal = error }
      }
    }
    guard let profile = chosen else {
      return .failure(
        Unsatisfiable(
          guest: r.guest, eliminated: eliminated, reasons: reasons, limit: firstRefusal))
    }

    // 8. Plan.
    let features = Feature.allCases.filter { required.contains($0) || has(profile, $0) }
    let requested = features.filter { required.contains($0) || preferred.contains($0) }
    let preferredDenied = preferred.filter { !has(profile, $0) }
    var unverified: [Feature] = []
    for feature in Feature.allCases where required.contains(feature) || preferred.contains(feature)
    {
      let onChosen = !Capabilities.unverifiedProbes(feature, on: profile, host: host).isEmpty
      let onEliminated = (eliminated[feature] ?? []).contains {
        !Capabilities.unverifiedProbes(feature, on: $0, host: host).isEmpty
      }
      if onChosen || onEliminated { unverified.append(feature) }
    }
    var planned = resources
    if profile == .qemuTCG, let cpus = planned.cpus, cpus > maxTCGCPUs {
      planned.cpus = maxTCGCPUs
    }
    return .success(
      Plan(
        profile: profile, guest: r.guest, resources: planned, features: features,
        requested: requested, preferredDenied: preferredDenied, unverified: unverified,
        allowUnverified: allowUnverified,
        estimatedStartupSeconds: estimatedStartupSeconds(profile, features: features, r: r),
        notes: notes(
          profile, r: r, required: required, granted: features, unverified: unverified,
          allowUnverified: allowUnverified, matrix: matrix)))
  }

  /// Subsets of `required` of size 1, then 2, then 3, whose removal leaves a survivor. A subset
  /// that contains a smaller successful one is skipped; within a size, the best resulting profile
  /// comes first. At most five.
  static func suggestions(
    required: [Feature], survivors: ([Feature]) -> [Profile], rankKey: (Profile) -> [Int]
  ) -> [Unsatisfiable.Suggestion] {
    var result: [Unsatisfiable.Suggestion] = []
    for size in 1...max(1, min(3, required.count)) where size <= required.count {
      var found: [Unsatisfiable.Suggestion] = []
      for indices in combinations(required.count, size) {
        let drop = indices.map { required[$0] }
        if result.contains(where: { Set($0.drop).isSubset(of: drop) }) { continue }
        let rest = required.filter { !drop.contains($0) }
        if let best = survivors(rest).first {
          found.append(.init(drop: drop, profile: best))
        }
      }
      let ordered = found.enumerated().sorted { a, b in
        let (ka, kb) = (rankKey(a.element.profile), rankKey(b.element.profile))
        return ka == kb ? a.offset < b.offset : ka.lexicographicallyPrecedes(kb)
      }.map(\.element)
      result += ordered
      if result.count >= 5 { break }
    }
    return Array(result.prefix(5))
  }

  /// Index combinations of `k` out of `n`, in lexicographic order.
  static func combinations(_ n: Int, _ k: Int) -> [[Int]] {
    guard k > 0 else { return [[]] }
    guard k <= n else { return [] }
    var out: [[Int]] = []
    func walk(_ start: Int, _ picked: [Int]) {
      if picked.count == k {
        out.append(picked)
        return
      }
      for i in start..<n where n - i >= k - picked.count { walk(i + 1, picked + [i]) }
    }
    walk(0, [])
    return out
  }

  /// The most virtual CPUs a `qemu-tcg` guest gets (R-310): emulated CPUs past this add little.
  public static let maxTCGCPUs = 8

  /// A rough figure for the model: time from start to a reachable guest.
  static func estimatedStartupSeconds(_ profile: Profile, features: [Feature], r: Requirements)
    -> Int
  {
    let base =
      switch profile {
      case .vzLinux: 15
      case .qemuHVF: 20
      case .vzMacOS: 60
      case .qemuTCG: 120
      }
    let desktop = r.guest.os == .linux && (r.require + r.prefer).contains(.guiDesktop)
    return base + (desktop ? 300 : 0)
  }

  static func notes(
    _ profile: Profile, r: Requirements, required: [Feature], granted: [Feature],
    unverified: [Feature], allowUnverified: Bool, matrix: [Profile: [Feature: Availability]]
  ) -> [String] {
    var notes: [String] = []
    let asked = Set(required + r.prefer).intersection(granted)
    if profile == .qemuTCG {
      notes.append(
        "qemu-tcg emulates the guest CPU: slow, expect many times the run time of hardware "
          + "virtualization")
    }
    if profile == .qemuTCG, let cpus = ResourceLimits.resolve(r.resources, for: r.guest.os).cpus,
      cpus > maxTCGCPUs
    {
      notes.append("qemu-tcg runs at most \(maxTCGCPUs) virtual CPUs; \(cpus) were asked for")
    }
    if case .other(let arch) = r.guest.arch {
      notes.append(
        "vmlab has no defaults for \(arch) beyond -machine virt: give boot (kernel, firmware or "
          + "binary) and any devices in extra.qemuArgs")
    }
    if profile == .qemuTCG, asked.contains(.nestedVirt) {
      var note = "nested virtualization is emulated under qemu-tcg and very slow"
      if case .no(let reason) = matrix[.vzLinux]?[.nestedVirt] {
        note += "; vz-linux was ruled out: \(reason)"
      }
      notes.append(note)
    }
    if r.guest.os == .linux, asked.contains(.guiDesktop) {
      notes.append("the desktop is installed on first boot, which adds several minutes")
    }
    if profile.isVZ, asked.contains(.netPortForward) {
      notes.append(
        "VZ guests get a host-reachable address: reach guest ports at the guest's IP rather than "
          + "a forwarded host port")
    }
    if !unverified.isEmpty {
      let names = unverified.map(\.rawValue).joined(separator: ", ")
      notes.append(
        allowUnverified
          ? "\(names) rest on probes not verified on this host and are treated as available "
            + "because allowUnverified is set"
          : "\(names) rest on probes not verified on this host; run host_doctor with probe: true")
    }
    return notes
  }
}

/// `ProfileSelector.select` as a free function, the spelling R-103 names.
public func select(
  _ r: Requirements, host: HostFacts, running: Inventory, allowUnverified: Bool = false
) -> Result<Plan, Unsatisfiable> {
  ProfileSelector.select(r, host: host, running: running, allowUnverified: allowUnverified)
}
