import Foundation
import Testing
import VMLabCore

@testable import VMLabEngines

@Suite struct EnginesTests {
  @Test func registerAllFillsEveryEngineProfile() throws {
    let registry = BackendRegistry()
    let store = Store(home: FileManager.default.temporaryDirectory.appending(path: "vmlab-engines"))
    let displays = DisplayConnectorRegistry()
    #expect(throws: VMLabError.self) { try displays.connector() }
    Engines.registerAll(store: store, into: registry, displays: displays)
    #expect(try displays.connector() is RFBDisplayConnector)
    #expect(Set(registry.profiles) == [.qemuHVF, .qemuTCG, .vzLinux])
    #expect(Set(registry.profiles) == Set(Engines.profiles))
    for profile in Engines.profiles {
      #expect(try registry.backend(for: profile).profile == profile)
    }
    #expect(throws: VMLabError.self) { try registry.backend(for: .vzMacOS) }
  }

  @Test func registerProbesFillsTheEngineProbes() {
    let registry = SlowProbeRegistry()
    Engines.registerProbes(into: registry)
    #expect(
      registry.probes == [.qemuHVFGDB, .qemuHVFLiveSnapshot, .qemuVmnet, .vzLinuxLiveSnapshot])
    #expect(registry.runner(for: .vzMacOSLiveSnapshot) == nil)
    #expect(registry.runner(for: .qemuHVFGDB) is HVFGDBProbe)
  }

  @Test func hvfGDBProbeBootsAHaltedDisklessMachine() {
    let arguments = HVFGDBProbe.arguments(port: 4321)
    #expect(arguments.contains("-S"))
    #expect(arguments.joined(separator: " ").contains("-accel hvf"))
    #expect(arguments.joined(separator: " ").contains("-gdb tcp:127.0.0.1:4321"))
    #expect(!arguments.contains("-drive"))
  }
}
