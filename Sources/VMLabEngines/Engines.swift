import VMLabCore
import VMLabGDB
import VMLabQEMU
import VMLabRFB
import VMLabVZ

/// The one place that names the engines: `vmlab` calls `registerAll` at startup so `VMManager`
/// can reach QEMU and VZ through `Backends`, while the CLI and the MCP layer import no backend
/// module themselves (constraint C3).
public enum Engines {
  /// The profiles `registerAll` fills.
  public static let profiles: [Profile] = [.qemuHVF, .qemuTCG, .vzLinux, .vzMacOS]

  /// Registers QEMU for `qemu-hvf` and `qemu-tcg` and VZ for `vz-linux` and
  /// `vz-macos`, all on `store`, the RFB
  /// display connector every profile's display speaks (R-502), and the GDB client as the
  /// connector of `vm_debug`'s sessions (R-701).
  public static func registerAll(
    store: Store, into registry: BackendRegistry = Backends.shared,
    displays: DisplayConnectorRegistry = Displays.shared, debug: DebugSessions = .shared
  ) {
    registry.register(QEMUBackend(profile: .qemuHVF, store: store))
    registry.register(QEMUBackend(profile: .qemuTCG, store: store))
    registry.register(VZBackend(store: store))
    registry.register(VZMacBackend(store: store))
    displays.register(RFBDisplayConnector())
    debug.register(GDBDebugConnector())
  }

  /// Registers the slow probes the engine modules own (`vmlab doctor --probe` runs them): QEMU's,
  /// and `qemu_hvf_gdb` (R-702), which needs both QEMU and the GDB client.
  public static func registerProbes(into registry: SlowProbeRegistry = SlowProbeRunners.shared) {
    for runner in VMLabQEMU.probeRunners { registry.register(runner) }
    registry.register(HVFGDBProbe())
  }
}
