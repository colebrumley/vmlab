import VMLabCore
import VMLabQEMU
import VMLabVZ

/// The one place that names the engines: `vmlab` calls `registerAll` at startup so `VMManager`
/// can reach QEMU and VZ through `Backends`, while the CLI and the MCP layer import no backend
/// module themselves (constraint C3).
public enum Engines {
  /// The profiles `registerAll` fills.
  public static let profiles: [Profile] = [.qemuHVF, .qemuTCG, .vzLinux, .vzMacOS]

  /// Registers QEMU for `qemu-hvf` and `qemu-tcg` and VZ for `vz-linux` and `vz-macos`, all on
  /// `store`.
  public static func registerAll(store: Store, into registry: BackendRegistry = Backends.shared) {
    registry.register(QEMUBackend(profile: .qemuHVF, store: store))
    registry.register(QEMUBackend(profile: .qemuTCG, store: store))
    registry.register(VZBackend(store: store))
    registry.register(VZMacBackend(store: store))
  }

  /// Registers the slow probes the engine modules own (`vmlab doctor --probe` runs them).
  public static func registerProbes(into registry: SlowProbeRegistry = SlowProbeRunners.shared) {
    for runner in VMLabQEMU.probeRunners { registry.register(runner) }
  }
}
