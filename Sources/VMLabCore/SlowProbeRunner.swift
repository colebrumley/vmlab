import Foundation
import Synchronization

extension SlowProbe {
  /// The backlog item that builds this probe (Appendix E).
  public var owner: String {
    switch self {
    case .qemuHVFLiveSnapshot: "R-307"
    case .qemuHVFGDB: "R-702"
    case .qemuVmnet: "R-309"
    case .vzLinuxLiveSnapshot, .vzMacOSLiveSnapshot: "R-608"
    }
  }
}

/// What a slow probe may use: the `VMLAB_HOME` to create its throwaway guest under, and the fast
/// host facts gathered just before (tool paths, versions).
public struct SlowProbeContext: Sendable {
  public var home: URL
  public var facts: HostFacts

  public init(home: URL, facts: HostFacts) {
    self.home = home
    self.facts = facts
  }
}

/// One slow probe: boots a throwaway minimal guest, tries the feature, destroys the guest and
/// answers. Return `.unknown` when the probe cannot run here (no macOS image pulled, say); throw
/// when it failed for a reason that says nothing about the feature. Items that own a probe
/// (R-307, R-309, R-608, R-702) conform a type and register it with `SlowProbeRunners.register`.
public protocol SlowProbeRunner: Sendable {
  var probe: SlowProbe { get }
  func run(_ context: SlowProbeContext) async throws(VMLabError) -> ProbeResult
}

/// What running one slow probe came to.
public struct SlowProbeOutcome: Sendable, Equatable {
  public enum Status: String, Sendable, Equatable {
    /// The runner answered `yes` or `no`; the answer was persisted.
    case ran
    /// The runner could not decide here (it returned `unknown`); nothing was persisted.
    case skipped
    /// The runner threw; nothing was persisted.
    case failed
    /// No runner is registered: the owning item has not been built.
    case notImplemented = "not_implemented"
  }

  public var probe: SlowProbe
  public var status: Status
  public var result: ProbeResult
  /// Why it did not run, or the error it failed with.
  public var note: String?

  public init(probe: SlowProbe, status: Status, result: ProbeResult, note: String? = nil) {
    self.probe = probe
    self.status = status
    self.result = result
    self.note = note
  }
}

/// The registered slow probe runners, at most one per probe.
public final class SlowProbeRegistry: Sendable {
  private let runners = Mutex<[SlowProbe: any SlowProbeRunner]>([:])

  public init() {}

  /// Registers `runner` for its probe, replacing any earlier one.
  public func register(_ runner: any SlowProbeRunner) {
    runners.withLock { $0[runner.probe] = runner }
  }

  public func unregister(_ probe: SlowProbe) {
    _ = runners.withLock { $0.removeValue(forKey: probe) }
  }

  public func runner(for probe: SlowProbe) -> (any SlowProbeRunner)? {
    runners.withLock { $0[probe] }
  }

  /// The probes that have a runner, in name order.
  public var probes: [SlowProbe] { runners.withLock { $0.keys.sorted() } }

  /// Runs every probe in name order, one at a time (each boots a guest), and persists each `yes`
  /// or `no` to `host-facts.json` under `context.home` with the OS and QEMU versions of
  /// `context.facts`. A probe without a runner is reported `not_implemented` and left as it was.
  ///
  /// `docs/FEATURES.md` reads the committed snapshot `docs/dev-host-facts.json`, not this file:
  /// after recording results on the development host, run `scripts/gen-docs.sh
  /// --refresh-host-facts` and commit the snapshot with the regenerated document.
  public func runAll(_ context: SlowProbeContext, now: @Sendable () -> Date = { Date() }) async
    -> [SlowProbeOutcome]
  {
    var outcomes: [SlowProbeOutcome] = []
    for probe in SlowProbe.allCases.sorted() {
      guard let runner = runner(for: probe) else {
        outcomes.append(
          SlowProbeOutcome(
            probe: probe, status: .notImplemented, result: context.facts.probe(probe),
            note: "not yet implemented (\(probe.owner))"))
        continue
      }
      do {
        let result = try await runner.run(context)
        guard result != .unknown else {
          outcomes.append(
            SlowProbeOutcome(
              probe: probe, status: .skipped, result: context.facts.probe(probe),
              note: "the probe could not run on this host"))
          continue
        }
        outcomes.append(SlowProbeOutcome(probe: probe, status: .ran, result: result))
      } catch {
        outcomes.append(
          SlowProbeOutcome(
            probe: probe, status: .failed, result: context.facts.probe(probe),
            note: "\(error.code.rawValue): \(error.message)"))
      }
    }
    let answered = outcomes.filter { $0.status == .ran }
    if !answered.isEmpty {
      let url = SlowProbes.url(home: context.home)
      var stored = (try? SlowProbes.load(from: url)) ?? SlowProbes()
      let date = now()
      for outcome in answered {
        stored.record(
          outcome.probe, outcome.result, at: date, osVersion: context.facts.osVersion,
          qemuVersion: context.facts.qemu.version)
      }
      do {
        try stored.save(to: url)
      } catch {
        outcomes = outcomes.map { outcome in
          guard outcome.status == .ran else { return outcome }
          var failed = outcome
          failed.status = .failed
          failed.note = "could not write \(url.path): \(error)"
          return failed
        }
      }
    }
    return outcomes
  }
}

/// The process-wide slow probe registry that `vmlab` fills at startup.
public enum SlowProbeRunners {
  public static let shared = SlowProbeRegistry()

  public static func register(_ runner: any SlowProbeRunner) { shared.register(runner) }
}
