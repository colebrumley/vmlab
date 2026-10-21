import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite struct QEMUTCGIntegrationTests {
  /// R-310 Verify (integration, slow): `debian-13-amd64` under qemu-tcg (`qemu-system-x86_64`,
  /// q35, edk2 x86 firmware) reaches `login:` on serial within 10 minutes.
  @Test(.enabled(if: integrationEnabled), .tags(.slow), .timeLimit(.minutes(12)))
  func debianAmd64BootsToLoginUnderTCG() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .netNAT], memoryGB: 2, profile: .qemuTCG,
      guest: GuestSpec(os: .linux, arch: .x86_64), image: "debian-13-amd64", cpus: 4)
    do {
      let log = try String(contentsOf: guest.machine.layout.log, encoding: .utf8)
      #expect(log.contains("qemu-system-x86_64") && log.contains("-machine q35 -accel tcg"))
      #expect(log.contains("edk2-x86_64-code.fd"))
      let started = ContinuousClock.now
      _ = try await guest.machine.serial.wait(for: "login:", since: 0, timeout: .seconds(600))
      print("debian-13-amd64 under TCG reached login: in \(ContinuousClock.now - started)")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-1204 Verify (integration, slow): the W1 bare kernel with `require: ["cpu_emulation",
  /// "serial"]` (and `net_none`) plans onto `qemu-tcg` and prints its message on serial within
  /// 120 seconds of start.
  @Test(.enabled(if: integrationEnabled), .tags(.slow), .timeLimit(.minutes(4)))
  func bareKernelUnderEmulation() async throws {
    let lab = try await QEMUBootIntegrationTests.BareServer(tag: "e")
    defer { lab.shutdown() }
    let message = "bare kernel under emulation"
    let kernel = lab.home.appending(path: "bare-tcg.img")
    try BareKernel.write(to: kernel, message: message, then: .halt)
    // W3 has not landed: the kernel boot still names the Debian image, which it ignores, and
    // net_none keeps start from waiting for an SSH server the bare kernel never runs.
    let requirements: JSONValue = [
      "guest": ["os": "linux", "arch": "arm64"],
      "require": ["cpu_emulation", "serial", "net_none"],
      "resources": ["cpus": 1, "memoryGB": 1], "image": "debian-13-arm64",
      "boot": ["mode": "kernel", "kernel": .string(kernel.path)],
    ]
    let made = try await lab.server.call(
      "vm_create", ["requirements": requirements, "name": "bare-tcg", "autostart": false])
    try #require(made.isError == false, "\(made.text)")
    try #require(made.value["plan"]?["profile"]?.stringValue == "qemu-tcg", "\(made.text)")
    let features = made.value["plan"]?["features"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(features.contains("cpu_emulation"), "\(features)")

    let started = ContinuousClock.now
    let start = try await lab.server.call(
      "vm_lifecycle", ["vm": "bare-tcg", "action": "start"])
    try #require(start.isError == false, "\(start.text)")
    let wait = try await lab.server.call(
      "vm_serial",
      ["vm": "bare-tcg", "action": "wait", "pattern": .string(message), "timeoutSeconds": 120])
    #expect(wait.isError == false, "\(wait.text) console: \(lab.console("bare-tcg"))")
    #expect(ContinuousClock.now - started < .seconds(120))
    print("bare kernel under qemu-tcg printed in \(ContinuousClock.now - started)")
  }
}
