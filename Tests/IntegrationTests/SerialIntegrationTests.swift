import Foundation
import Testing
import VMLabCore

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
    try process.run()
    let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
    await Task.detached { process.waitUntilExit() }.value
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
      _ = try await guest.machine.serial.wait(for: "login:", since: 0, timeout: .seconds(120))
      // Let go of the socket, as a CLI call does when it exits.
      await guest.machine.disconnect()
      let name = guest.record.name
      let boot = try await Self.cli(guest.home, [name, "wait", "login:", "--since", "0"])
      #expect(boot["matched"] == "login:")
      let written = try await Self.cli(guest.home, [name, "write", "\\n"])
      let mark = try #require(written["offset"]?.numberValue)
      try await Task.sleep(for: .seconds(2))  // the guest answers while nobody listens
      let reply = try await Self.cli(
        guest.home, [name, "wait", "login:", "--since", String(Int(mark)), "--timeout", "30"])
      #expect(reply["matched"] == "login:")
      #expect((reply["offset"]?.numberValue ?? 0) > mark)
      let tail = try await Self.cli(guest.home, [name, "tail", "--lines", "2"])
      #expect(tail["text"]?.stringValue?.contains("login:") == true)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
