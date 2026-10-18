import VMLabCore
import VMLabQEMU
import VMLabRFB
import VMLabVZ

/// The one place that names the engines: `vmlab` calls `registerAll` at startup so `VMManager`
/// can reach QEMU and VZ through `Backends`, while the CLI and the MCP layer import no backend
/// module themselves (constraint C3).
public enum Engines {
  /// The profiles `registerAll` fills. `vz-macos` joins when `VZBackend` runs macOS guests.
  public static let profiles: [Profile] = [.qemuHVF, .qemuTCG, .vzLinux]

  /// Registers QEMU for `qemu-hvf` and `qemu-tcg` and VZ for `vz-linux`, all on `store`, and
  /// the RFB display connector every profile's display speaks (R-502).
  public static func registerAll(
    store: Store, into registry: BackendRegistry = Backends.shared,
    displays: DisplayConnectorRegistry = Displays.shared
  ) {
    registry.register(QEMUBackend(profile: .qemuHVF, store: store))
    registry.register(QEMUBackend(profile: .qemuTCG, store: store))
    registry.register(VZBackend(store: store))
    displays.register(RFBDisplayConnector())
  }
}
