import Darwin
import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite struct QEMUBootIntegrationTests {
  /// R-305 Verify (integration): boot the Debian cloud kernel and initrd extracted from the pulled
  /// image (`images extract-kernel debian-13-arm64`) with `console=ttyAMA0 root=/dev/vda1` and
  /// reach `login:` on serial.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
  func extractedDebianKernelBootsToLogin() async throws {
    let images = ImageStore(
      home: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab"))
    let files = try await images.extractKernel("debian-13-arm64")
    #expect(files.version?.contains("arm64") == true)
    #expect(files.initrd != nil && files.config != nil)

    let guest = try await QEMUGuest.boot(
      features: [.serial, .directKernelBoot, .netNAT],
      boot: BootSpec(mode: .kernel, cmdline: "console=ttyAMA0 root=/dev/vda1"))
    do {
      let args = try String(contentsOf: guest.machine.layout.log, encoding: .utf8)
      #expect(
        args.contains("-kernel /tmp/vmlab-test-") && args.contains("debian-13-arm64/kernel/vmlinuz")
      )
      #expect(!args.contains("if=pflash"))
      _ = try await guest.machine.serial.wait(for: "login:", since: 0, timeout: .seconds(90))
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-1200 Verify (unit): two messages give two images that differ, each holding its message and
  /// ending in `\n`, with the `Image` header's magic at byte 56 and `code0` branching over it.
  @Test func bareKernelBytes() {
    let a = BareKernel.image(message: "bare kernel A", then: .powerOff)
    let b = BareKernel.image(message: "bare kernel B\n", then: .powerOff)
    #expect(a != b)
    for (image, message) in [(a, "bare kernel A\n"), (b, "bare kernel B\n")] {
      #expect(image[56..<60] == Data("ARMd".utf8))
      #expect(image.prefix(4) == Data([0x10, 0x00, 0x00, 0x14]))  // b #64
      #expect(image[8..<16] == Data([0x00, 0x00, 0x08, 0, 0, 0, 0, 0]))  // text_offset 0x80000
      #expect(Self.u64(image, at: 16) == UInt64(image.count))
      #expect(image.suffix(message.utf8.count + 1) == Data(message.utf8) + Data([0]))
    }
    // The code as `clang -target arm64` assembles it: adr, movz, the print loop, PSCI SYSTEM_OFF
    // through hvc, then wfi in a loop.
    let words = (0..<11).map { UInt32(Self.u64(a, at: 64 + $0 * 4) & 0xFFFF_FFFF) }
    #expect(
      words == [
        0x1000_0161, 0xD2A1_2002, 0x3840_1423, 0x3400_0063, 0x3900_0043, 0x17FF_FFFD,
        0xD280_0100, 0xF2B0_8000, 0xD400_0002, 0xD503_207F, 0x17FF_FFFF,
      ])
    let halt = BareKernel.image(message: "bare kernel A", then: .halt)
    #expect(halt != a && !halt.contains(Data([0x02, 0x00, 0x00, 0xD4])))  // no hvc
  }

  static func u64(_ data: Data, at offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
  }

  /// A `vmlab serve` child in a fresh home that links `~/.vmlab/images`, the written kernels' home.
  struct BareServer {
    let home: URL
    let server: StdioMCPClient

    init(tag: String) async throws {
      home = URL(filePath: "/tmp/vmlab-test-\(getpid())-bk\(tag)")
      try? FileManager.default.removeItem(at: home)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: home.appending(path: "images"),
        withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appending(
          path: ".vmlab/images"))
      server = try StdioMCPClient(
        binary: try TwoServersIntegrationTests.vmlabURL(), home: home, tag: tag)
      try await server.initialize()
    }

    /// Writes a kernel printing `message` and creates (without starting) a `qemu-hvf` VM that boots it.
    func create(_ name: String, message: String, then: BareKernel.Then) async throws {
      let kernel = home.appending(path: "\(name).img")
      try BareKernel.write(to: kernel, message: message, then: then)
      // W3 has not landed: the kernel boot ignores the image. Serial and net_none alone land on
      // vz-linux; preferring introspection, which qemu-hvf grants without a probe and VZ never does,
      // keeps it on qemu-hvf, whose PL011 the kernel writes to.
      let requirements: JSONValue = [
        "guest": ["os": "linux", "arch": "arm64"], "require": ["serial", "net_none"],
        "prefer": ["introspection"],
        "resources": ["cpus": 1, "memoryGB": 1], "image": "debian-13-arm64",
        "boot": ["mode": "kernel", "kernel": .string(kernel.path)],
      ]
      let made = try await server.call(
        "vm_create", ["requirements": requirements, "name": .string(name), "autostart": false])
      try #require(made.isError == false, "\(made.text)")
      try #require(made.value["plan"]?["profile"]?.stringValue == "qemu-hvf", "\(made.text)")
    }

    func state(_ name: String) -> String {
      (try? Store(home: home).find(name).state.rawValue) ?? ""
    }

    func console(_ name: String) -> String {
      guard let id = try? Store(home: home).find(name).id else { return "" }
      let log = Store(home: home).directory(of: id).appending(path: "console.log")
      return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    func shutdown() {
      server.terminate()
      for pid in TwoServersIntegrationTests.qemuPIDs(in: home) { kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: home)
    }
  }

  /// R-1200 Verify (integration): a `qemu-hvf` guest booting the bare kernel prints its message on
  /// serial and is `stopped` within ten seconds of `start`, the events log saying it powered off.
  /// Two kernels with different messages each print their own.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(2)))
  func bareKernelPowersOff() async throws {
    let lab = try await BareServer(tag: "o")
    defer { lab.shutdown() }
    for (name, message) in [("bare-a", "bare kernel A: poweroff"), ("bare-b", "bare kernel B")] {
      try await lab.create(name, message: message, then: .powerOff)
      let started = ContinuousClock.now
      let start = try await lab.server.call(
        "vm_lifecycle", ["vm": .string(name), "action": "start"])
      try #require(start.isError == false, "\(start.text)")
      while lab.state(name) != "stopped", ContinuousClock.now - started < .seconds(10) {
        try await Task.sleep(for: .milliseconds(100))
      }
      let elapsed = ContinuousClock.now - started
      #expect(lab.state(name) == "stopped", "\(name) after \(elapsed)")
      #expect(elapsed < .seconds(10), "\(name) stopped after \(elapsed)")
      // vm_serial refuses a stopped guest until W2; the console log is the record.
      let console = lab.console(name)
      #expect(console.contains(message + "\n"), "\(console)")
      #expect(!console.contains(name == "bare-a" ? "bare kernel B" : "bare kernel A"))
      let logs = try await lab.server.call("vm_logs", ["vm": .string(name), "source": "events"])
      let lines = logs.value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
      #expect(lines.contains { $0.contains("the guest powered off") }, "\(lines)")
    }
  }

  /// R-1200 Verify (integration): the `.halt` kernel prints its message and stays `running`.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(2)))
  func bareKernelHalts() async throws {
    let lab = try await BareServer(tag: "h")
    defer { lab.shutdown() }
    try await lab.create("bare-h", message: "bare kernel halts", then: .halt)
    let start = try await lab.server.call("vm_lifecycle", ["vm": "bare-h", "action": "start"])
    try #require(start.isError == false, "\(start.text)")
    let wait = try await lab.server.call(
      "vm_serial",
      ["vm": "bare-h", "action": "wait", "pattern": "bare kernel halts", "timeoutSeconds": 10])
    #expect(wait.value["matched"] == "bare kernel halts", "\(wait.text)")
    try await Task.sleep(for: .seconds(3))
    #expect(lab.state("bare-h") == "running")
    let kill = try await lab.server.call("vm_lifecycle", ["vm": "bare-h", "action": "kill"])
    #expect(kill.isError == false, "\(kill.text)")
    #expect(lab.state("bare-h") == "stopped")
  }
}
