import Foundation
import Testing
import VMLabCore
import VMLabMCP
import VMLabQEMU

@Suite struct ExecIntegrationTests {
  static let features: [Feature] = [.serial, .execSSH, .netNAT]

  /// R-400 Verify (integration): the start waits for SSH, then `uname -a` over the VM's key
  /// returns the kernel line with exit 0.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(5)))
  func unameOverSSH() async throws {
    let guest = try await QEMUGuest.boot(features: Self.features)
    do {
      #expect(guest.startWarnings.isEmpty, "\(guest.startWarnings)")
      let vm = try await guest.manager.attach(guest.record.id)
      let result = try await vm.channel(.exec).run(ExecRequest(command: "uname -a"))
      #expect(result.exitCode == 0)
      #expect(result.stdout.hasPrefix("Linux "), "\(result)")
      let dir = guest.manager.store.directory(of: guest.record.id)
      let knownHosts = try String(
        contentsOf: dir.appending(path: "known_hosts"), encoding: .utf8)
      #expect(knownHosts.hasPrefix(guest.record.id + " "))
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-401 Verify (integration): exit codes, stderr apart from stdout, a 200 KB output cut with
  /// its log path, and `sleep 300` with `timeoutSeconds: 2` back within 5 s; plus cwd, env,
  /// stdin and sudo to another user, all through the vm_exec handler.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(5)))
  func vmExecOnDebian() async throws {
    let guest = try await QEMUGuest.boot(features: Self.features)
    let registry = BackendRegistry()
    registry.register(guest.backend)
    let context = ToolContext(home: guest.home, backends: registry)
    func exec(_ arguments: [String: JSONValue]) async throws(VMLabError) -> JSONValue {
      var arguments = arguments
      arguments["vm"] = .string(guest.record.id)
      return try await ToolHandlers.call(
        "vm_exec", arguments: .object(arguments), context: context
      ).value
    }
    do {
      let codes = try await exec(["command": .string("echo out; echo err >&2; exit 7")])
      #expect(codes["exitCode"] == .number(7))
      #expect(codes["stdout"] == .string("out\n"))
      #expect(codes["stderr"] == .string("err\n"))
      #expect(codes["truncated"] == .bool(false))

      let ok = try await exec([
        "command": .string("pwd; echo \"$X\"; cat; id -un"), "cwd": .string("/etc"),
        "env": .object(["X": .string("it's set")]), "stdin": .string("piped\n"),
      ])
      #expect(ok["exitCode"] == .number(0))
      #expect(ok["stdout"] == .string("/etc\nit's set\npiped\ndebian\n"), "\(ok)")
      let root = try await exec(["command": .string("id -un"), "user": .string("root")])
      #expect(root["stdout"] == .string("root\n"), "\(root)")

      let big = try await exec(["command": .string("head -c 204800 /dev/zero | tr '\\0' 'a'")])
      #expect(big["truncated"] == .bool(true))
      let log = try #require(big["logPath"]?.stringValue)
      #expect(try Data(contentsOf: URL(filePath: log)).count == 204_800)
      #expect((big["stdout"]?.stringValue?.utf8.count ?? 0) < 66_000)

      let started = ContinuousClock.now
      do {
        _ = try await exec([
          "command": .string("echo started; sleep 300"), "timeoutSeconds": .number(2),
        ])
        Issue.record("sleep 300 returned without a timeout")
      } catch {
        #expect(error.code == .timeout)
        #expect(error.data["stdout"] == .string("started\n"))
      }
      #expect(ContinuousClock.now - started < .seconds(5))
      // The remote process group is gone.
      let left = try await exec([
        "command": .string("ps -eo pgid,args | grep '[s]leep 300' || true")
      ])
      #expect(left["stdout"] == .string(""), "\(left)")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }
}
