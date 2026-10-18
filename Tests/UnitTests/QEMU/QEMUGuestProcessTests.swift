import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite struct QEMUGuestProcessTests {
  @Test func memoryFlagForms() {
    #expect(VMLabQEMU.memoryGB(arguments: ["-m", "4096M"]) == 4)
    #expect(VMLabQEMU.memoryGB(arguments: ["-m", "2G"]) == 2)
    #expect(VMLabQEMU.memoryGB(arguments: ["-m", "512"]) == 0.5)
    #expect(VMLabQEMU.memoryGB(arguments: ["-m", "size=8G,slots=2,maxmem=16G"]) == 8)
    #expect(VMLabQEMU.memoryGB(arguments: ["-smp", "2"]) == 0.125)
    #expect(VMLabQEMU.memoryGB(arguments: ["-m", "lots"]) == nil)
  }

  @Test func recognizesAQEMUGuestWithItsDirectory() {
    let recognizer = VMLabQEMU.guestProcessRecognizer
    #expect(recognizer.matchesExecutable("/opt/homebrew/bin/qemu-system-aarch64"))
    #expect(!recognizer.matchesExecutable("/opt/homebrew/bin/qemu-img"))
    let process = HostProcessInfo(
      pid: 42, executable: "/opt/homebrew/bin/qemu-system-aarch64",
      arguments: [
        "-name", "vmlab-vm-a", "-m", "4096M", "-pidfile", "/h/vms/vm-a/qemu.pid", "-daemonize",
      ])
    #expect(
      recognizer.recognize(process)
        == HostGuestProcess(pid: 42, engine: "qemu", memoryGB: 4, directory: "/h/vms/vm-a"))
  }
}
