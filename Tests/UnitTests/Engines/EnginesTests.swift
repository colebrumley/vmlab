import Foundation
import Testing
import VMLabCore
import VMLabEngines

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

  @Test func registerProbesFillsTheQEMUProbes() {
    let registry = SlowProbeRegistry()
    Engines.registerProbes(into: registry)
    #expect(registry.probes == [.qemuHVFLiveSnapshot, .qemuVmnet])
  }
}
