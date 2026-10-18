import Foundation
import Testing
import VMLabCore
import VMLabVZ

@Suite struct VZGuestProcessTests {
  @Test func recognizesARunnerByItsConfig() throws {
    let vm = FileManager.default.temporaryDirectory.appending(path: "vmlab-vzproc-\(UUID())")
    try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
    try VZRunnerConfig(
      cpus: 2, memoryBytes: 6 << 30, boot: .efi(variableStore: "efi.bin"), disks: [],
      network: []
    ).write(to: VZRunnerPaths(vmDirectory: vm).config)
    let recognizer = VMLabVZ.guestProcessRecognizer
    #expect(recognizer.matchesExecutable("/x/.build/debug/vmlab-vz"))
    #expect(!recognizer.matchesExecutable("/x/.build/debug/vmlab"))
    let run = HostProcessInfo(pid: 9, executable: "/x/vmlab-vz", arguments: ["run", vm.path])
    #expect(
      recognizer.recognize(run)
        == HostGuestProcess(pid: 9, engine: "vz", memoryGB: 6, directory: vm.path))
    #expect(
      recognizer.recognize(HostProcessInfo(pid: 9, executable: "/x/vmlab-vz", arguments: ["probe"]))
        == nil)
    let gone = HostProcessInfo(pid: 10, executable: "/x/vmlab-vz", arguments: ["run", "/nope"])
    #expect(recognizer.recognize(gone)?.memoryGB == 4)
  }
}
