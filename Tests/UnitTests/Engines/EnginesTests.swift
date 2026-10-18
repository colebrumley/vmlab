import Foundation
import Testing
import VMLabCore

@testable import VMLabEngines

@Suite struct EnginesTests {
  @Test func registerAllFillsEveryEngineProfile() throws {
    let registry = BackendRegistry()
    let store = Store(home: FileManager.default.temporaryDirectory.appending(path: "vmlab-engines"))
    Engines.registerAll(store: store, into: registry)
    #expect(Set(registry.profiles) == [.qemuHVF, .qemuTCG, .vzLinux])
    #expect(Set(registry.profiles) == Set(Engines.profiles))
    for profile in Engines.profiles {
      #expect(try registry.backend(for: profile).profile == profile)
    }
    #expect(throws: VMLabError.self) { try registry.backend(for: .vzMacOS) }
  }

  /// R-702: the engines register the qemu_hvf_gdb probe for doctor --probe.
  @Test func registerAllRegistersTheEngineProbes() {
    let probes = SlowProbeRegistry()
    Engines.registerAll(
      store: Store(home: FileManager.default.temporaryDirectory.appending(path: "vmlab-engines")),
      into: BackendRegistry(), debug: DebugSessions(), probes: probes)
    #expect(probes.runner(for: .qemuHVFGDB) is HVFGDBProbe)
  }

  @Test func hvfGDBProbeBootsAHaltedDisklessMachine() {
    let arguments = HVFGDBProbe.arguments(port: 4321)
    #expect(arguments.contains("-S"))
    #expect(arguments.joined(separator: " ").contains("-accel hvf"))
    #expect(arguments.joined(separator: " ").contains("-gdb tcp:127.0.0.1:4321"))
    #expect(!arguments.contains("-drive"))
  }
}
