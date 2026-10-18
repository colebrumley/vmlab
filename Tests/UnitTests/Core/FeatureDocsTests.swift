import Foundation
import Testing
import VMLabCore

@Suite struct FeatureDocsTests {
  @Test func cellsReadAsAppendixB() {
    #expect(FeatureDocs.cell(Capabilities.entry(.execAgent, on: .qemuHVF)) == "Y (qemu-ga)")
    #expect(FeatureDocs.cell(Capabilities.entry(.manyGuests, on: .vzMacOS)) == "N (limit 2)")
    #expect(FeatureDocs.cell(Capabilities.entry(.serial, on: .vzMacOS)) == "N")
    #expect(
      FeatureDocs.cell(Capabilities.entry(.gdb, on: .qemuHVF)) == "? `qemu_hvf_gdb` (R-702)")
    #expect(
      FeatureDocs.cell(Capabilities.entry(.netFast, on: .qemuTCG)) == "C `root` or `qemu_vmnet`")
  }

  @Test func verifiedColumnComesFromHostFacts() throws {
    var probes = SlowProbes()
    let date = try Date("2026-10-18T12:00:00Z", strategy: .iso8601)
    probes.record(.qemuHVFGDB, .yes, at: date, osVersion: "26.6.2", qemuVersion: "11.1.2")
    #expect(FeatureDocs.verified(.gdb, probes: probes) == "`qemu_hvf_gdb`: yes, 2026-10-18")
    #expect(FeatureDocs.verified(.netFast, probes: probes) == "`qemu_vmnet`: unknown")
    #expect(FeatureDocs.verified(.serial, probes: probes) == "")
    let doc = FeatureDocs.markdown(probes: probes)
    #expect(
      doc.contains(
        "| `gdb` | N | N | ? `qemu_hvf_gdb` (R-702) | Y | `qemu_hvf_gdb`: yes, 2026-10-18 |"))
    #expect(
      doc.contains(
        "| Feature | vz-macos | vz-linux | qemu-hvf | qemu-tcg | verified on dev host |"))
  }
}
