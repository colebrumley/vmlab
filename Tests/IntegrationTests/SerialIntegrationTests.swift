import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@testable import VMLabMCP

@Suite struct SerialIntegrationTests {
  /// CPU seconds used by this process's reaped children (the `vmlab-match` helpers here).
  static func childCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_CHILDREN, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
  }

  /// R-303 Verify (integration): the Debian boot log contains `login:` within 90 s via `wait`.
  /// The match runs in `vmlab-match` helpers across the whole boot; their CPU stays small.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
  func debianBootReachesLoginPrompt() async throws {
    let guest = try await QEMUGuest.boot(features: [.serial, .netNAT])
    do {
      let cpuBefore = Self.childCPUSeconds()
      // The channel connected before `cont`, so the log starts at the first byte of firmware output.
      let match = try await guest.machine.serial.wait(
        for: "login:", since: 0, timeout: .seconds(90))
      #expect(match.offset > 0)
      // The helper is killed once the wait matched; wait for it to be reaped, then count its CPU.
      try await Task.sleep(for: .milliseconds(500))
      let matcherCPU = Self.childCPUSeconds() - cpuBefore
      print("serial wait: matched at offset \(match.offset); matcher CPU \(matcherCPU) s")
      #expect(matcherCPU < 2)
      let head = await guest.machine.serial.read(since: 0, maxBytes: 4096)
      #expect(head.start == 0 && !head.text.isEmpty)
      // The offsets are console.log's, which QEMU wrote from the first byte.
      let log = try String(contentsOf: guest.machine.layout.consoleLog, encoding: .utf8)
      #expect(log.contains("login:"))
      #expect(UInt64(log.utf8.count) >= match.offset)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// Runs `vmlab serial <vm> <arguments> --json` as its own process against `home` and returns
  /// the printed result object.
  static func cli(_ home: URL, _ arguments: [String]) async throws -> JSONValue {
    let process = Process()
    process.executableURL = try TwoServersIntegrationTests.vmlabURL()
    process.arguments = ["serial"] + arguments + ["--json"]
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["VMLAB_HOME": home.path]) { $1 }
    let out = Pipe()
    process.standardOutput = out
    // A termination handler, not waitUntilExit: that spins a run loop a detached task lacks.
    let exited = AsyncStream<Void> { continuation in
      process.terminationHandler = { _ in continuation.finish() }
    }
    try process.run()
    let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
    for await _ in exited {}
    #expect(process.terminationStatus == 0, "vmlab serial \(arguments)")
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// Serial by hand (G6): every `vmlab serial` call is a fresh process with its own channel, and
  /// offsets still carry over, because they are console.log's. A wait in a later call sees what
  /// the guest printed after an earlier call wrote, while no process held the socket.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(4)))
  func cliCallsShareOffsetsThroughTheConsoleLog() async throws {
    let guest = try await QEMUGuest.boot(features: [.serial, .netNAT])
    do {
      _ = try await guest.machine.serial.wait(
        for: "(automatic login)", since: 0, timeout: .seconds(120))
      // Let go of the socket, as a CLI call does when it exits.
      await guest.machine.disconnect()
      let name = guest.record.name
      let boot = try await Self.cli(guest.home, [name, "wait", "login:", "--since", "0"])
      #expect(boot["matched"] == "login:")
      let written = try await Self.cli(guest.home, [name, "write", "echo vmlab-$((6*7))\\n"])
      let mark = try #require(written["offset"]?.numberValue)
      try await Task.sleep(for: .seconds(2))  // the guest answers while nobody listens
      let reply = try await Self.cli(
        guest.home, [name, "wait", "vmlab-42", "--since", String(Int(mark)), "--timeout", "30"])
      #expect(reply["matched"] == "vmlab-42")
      #expect((reply["offset"]?.numberValue ?? 0) > mark)
      let tail = try await Self.cli(guest.home, [name, "tail", "--lines", "3"])
      #expect(tail["text"]?.stringValue?.contains("vmlab-42") == true)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// The serial console is a root shell on a Linux guest granted `serial` (cloud-init's getty
  /// autologin), so it is usable when SSH is not: through `vm_serial`, `id` says uid 0.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(4)))
  func serialConsoleIsARootShell() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-rc")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab/images"))
    let store = Store(home: home)
    let registry = BackendRegistry()
    let backend = QEMUBackend(profile: .qemuHVF, store: store)
    registry.register(backend)
    let context = ToolContext(home: home, backends: registry, startGate: IntegrationAdmission.gate)
    let plan = Plan(
      profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2, diskGB: 8), features: [.serial, .netNAT],
      estimatedStartupSeconds: 15)
    let created = try await context.manager.create(
      VMRecord(
        id: "", name: "rootcon", profile: .qemuHVF, guest: plan.guest, features: plan.features,
        image: "debian-13-arm64"), plan: plan)
    defer {
      if let record = try? store.load(id: created.id), let pid = record.runtime?.pid {
        kill(pid, SIGKILL)
      }
      try? FileManager.default.removeItem(at: home)
    }
    _ = try await context.manager.performAdmitted(.start, on: created.id)
    func serial(_ arguments: [String: JSONValue]) async throws -> ToolResult {
      var arguments = arguments
      arguments["vm"] = .string(created.id)
      return try await ToolHandlers.call(
        "vm_serial", arguments: .object(arguments), context: context)
    }
    _ = try await serial([
      "action": "wait", "pattern": "(automatic login)", "timeoutSeconds": 120,
    ])
    let enter = try await serial(["action": "write", "text": "\n"])
    let prompt = try await serial([
      "action": "wait", "pattern": "root@", "since": enter.value["offset"] ?? 0,
      "timeoutSeconds": 30,
    ])
    #expect(prompt.value["matched"] == "root@")
    let id = try await serial(["action": "write", "text": "id\n"])
    let answer = try await serial([
      "action": "wait", "pattern": "uid=[0-9]+", "since": id.value["offset"] ?? 0,
      "timeoutSeconds": 30,
    ])
    #expect(answer.value["matched"] == "uid=0")
    _ = try? await backend.kill(store.load(id: created.id))
  }

  /// R-1201 Verify (integration): the bare kernel powers off (`SYSTEM_OFF`). It starts halted
  /// (`haltAtStart`), so a wait for a pattern it never prints is registered on the live channel
  /// before `vm_debug continue` lets it run; the wait returns `stopped: true` with its message
  /// within two seconds rather than waiting out its timeout. Once the VM is `stopped`, `read`
  /// returns the message, `write` is `wrong_state`, and `vmlab serial wait` from the CLI says
  /// `stopped: true`.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(2)))
  func aPoweredOffGuestEndsAWaitAndStaysReadable() async throws {
    let lab = try await QEMUBootIntegrationTests.BareServer(tag: "so")
    defer { lab.shutdown() }
    let message = "w2 kernel says goodbye"
    let kernel = lab.home.appending(path: "bare-off.img")
    try BareKernel.write(to: kernel, message: message, then: .powerOff)
    let requirements: JSONValue = [
      "guest": ["os": "linux", "arch": "arm64"],
      "require": ["serial", "net_none", "gdb", "halt_at_start"],
      "resources": ["cpus": 1, "memoryGB": 1], "image": "debian-13-arm64",
      "boot": ["mode": "kernel", "kernel": .string(kernel.path), "haltAtStart": true],
    ]
    let made = try await lab.server.call(
      "vm_create", ["requirements": requirements, "name": "bare-off"])
    try #require(made.isError == false, "\(made.text)")
    try #require(made.value["plan"]?["profile"]?.stringValue == "qemu-hvf", "\(made.text)")
    try #require(lab.state("bare-off") == "running")
    let server = lab.server
    let waiting = Task {
      try await server.call(
        "vm_serial",
        ["vm": "bare-off", "action": "wait", "pattern": "never printed", "timeoutSeconds": 60])
    }
    // The CPU is halted, so the wait can only be pending while it registers; give it ample time.
    try await Task.sleep(for: .seconds(2))
    let pid = try #require(TwoServersIntegrationTests.qemuPIDs(in: lab.home).first)
    let go = try await lab.server.call("vm_debug", ["vm": "bare-off", "action": "continue"])
    try #require(go.isError == false, "\(go.text)")
    let continued = ContinuousClock.now
    // Time the wait from the engine's exit, as the acceptance does.
    while kill(pid, 0) == 0, ContinuousClock.now - continued < .seconds(10) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let exited = ContinuousClock.now
    let wait = try await waiting.value
    let elapsed = ContinuousClock.now - exited
    #expect(wait.value["stopped"] == true, "\(wait.text)")
    #expect(wait.value["matched"] == nil)
    #expect(wait.value["text"]?.stringValue?.contains(message) == true, "\(wait.text)")
    #expect(elapsed < .seconds(2), "the wait ended \(elapsed) after QEMU exited")
    while lab.state("bare-off") != "stopped", ContinuousClock.now - continued < .seconds(15) {
      try await Task.sleep(for: .milliseconds(100))
    }
    try #require(lab.state("bare-off") == "stopped")
    let read = try await lab.server.call("vm_serial", ["vm": "bare-off", "action": "read"])
    #expect(read.isError == false, "\(read.text)")
    #expect(read.value["text"]?.stringValue?.contains(message + "\n") == true, "\(read.text)")
    let again = try await lab.server.call(
      "vm_serial", ["vm": "bare-off", "action": "wait", "pattern": "never printed"])
    #expect(again.value["stopped"] == true, "\(again.text)")
    let write = try await lab.server.call(
      "vm_serial", ["vm": "bare-off", "action": "write", "text": "x\n"])
    #expect(write.isError == true)
    #expect(write.text.contains("wrong_state"), "\(write.text)")
    let cli = try await Self.cli(lab.home, ["bare-off", "wait", "never printed"])
    #expect(cli["stopped"] == true, "\(cli)")
    #expect(cli["text"]?.stringValue?.contains(message) == true, "\(cli)")
  }

  /// R-1201: a running guest killed during a wait (the halting kernel, its QEMU SIGKILLed) ends the
  /// wait with `stopped: true` within two seconds of the engine's exit, though the record still
  /// says `running` then.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(2)))
  func aKilledGuestEndsAWait() async throws {
    let lab = try await QEMUBootIntegrationTests.BareServer(tag: "sk")
    defer { lab.shutdown() }
    let message = "w2 kernel idles"
    try await lab.create("bare-kill", message: message, then: .halt)
    let start = try await lab.server.call("vm_lifecycle", ["vm": "bare-kill", "action": "start"])
    try #require(start.isError == false, "\(start.text)")
    let printed = try await lab.server.call(
      "vm_serial",
      ["vm": "bare-kill", "action": "wait", "pattern": .string(message), "timeoutSeconds": 10])
    try #require(printed.value["matched"] == .string(message), "\(printed.text)")
    let server = lab.server
    let waiting = Task {
      try await server.call(
        "vm_serial",
        ["vm": "bare-kill", "action": "wait", "pattern": "never printed", "timeoutSeconds": 60])
    }
    try await Task.sleep(for: .milliseconds(500))
    let pids = TwoServersIntegrationTests.qemuPIDs(in: lab.home)
    try #require(!pids.isEmpty)
    for pid in pids { kill(pid, SIGKILL) }
    let killed = ContinuousClock.now
    let wait = try await waiting.value
    let elapsed = ContinuousClock.now - killed
    #expect(wait.value["stopped"] == true, "\(wait.text)")
    #expect(wait.value["text"]?.stringValue?.contains(message) == true, "\(wait.text)")
    #expect(elapsed < .seconds(2), "the wait ended \(elapsed) after the kill")
  }
}
