import Foundation
import Testing
import VMLabCore
import VMLabGDB
import VMLabMCP
import VMLabQEMU

@Suite struct DebugIntegrationTests {
  /// `vm_debug` on `guest`, through the MCP handler with a GDB-backed session registry.
  struct Debugger {
    let context: ToolContext
    let vm: String

    init(_ guest: QEMUGuest) {
      var context = ToolContext(home: guest.home, backends: guest.backends)
      context.debug = DebugSessions(connector: GDBDebugConnector())
      self.context = context
      vm = guest.record.id
    }

    func callAsFunction(_ action: String, _ extra: [String: JSONValue] = [:]) async throws
      -> JSONValue
    {
      var arguments: [String: JSONValue] = ["vm": .string(vm), "action": .string(action)]
      arguments.merge(extra) { $1 }
      return try await ToolHandlers.call(
        "vm_debug", arguments: .object(arguments), context: context
      ).value
    }

    func close() async { await context.debug.drop(vm) }
  }

  /// R-701 Verify, arm64 variant (the x86_64 one needs R-305 and R-310): a `debian-13-arm64`
  /// guest under `qemu-tcg` with `gdb`. Halt, read the pc and the instruction there, set a
  /// software breakpoint at the halted pc, continue, and `wait` stops on it. A pc the guest does
  /// not pass again is retried at the next halt.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(6)))
  func haltBreakContinueWaitUnderTCG() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .gdb, .netNAT], memoryGB: 1, profile: .qemuTCG)
    let debug = Debugger(guest)
    do {
      // Let the kernel start, so the CPU is in a loop it revisits.
      _ = try await guest.machine.serial.wait(
        for: "Linux version|EFI stub", since: 0, timeout: .seconds(120))

      let info = try await debug("info")
      #expect(info["attached"] == .bool(false))
      #expect(
        info["endpoint"]?.stringValue == guest.record.runtime?.gdbEndpoint?.dropFirst(4).description
      )

      var hit: JSONValue?
      for _ in 0..<6 {
        let halted = try await debug("halt")
        #expect(halted["stopped"] == .bool(true))
        let pc = try #require(halted["pc"]?.stringValue)
        let registers = try await debug("registers")
        #expect(
          registers["registers"]?["pc"]?.stringValue.flatMap { UInt64($0.dropFirst(2), radix: 16) }
            == UInt64(pc.dropFirst(2), radix: 16))
        #expect(registers["registers"]?["sp"] != nil)
        let code = try await debug("read_memory", ["address": .string(pc), "size": .number(4)])
        #expect(code["bytes"]?.stringValue?.count == 8)

        _ = try await debug("breakpoint_add", ["address": .string(pc)])
        #expect(try await debug("continue")["stopped"] == .bool(false))
        do {
          let stop = try await debug("wait", ["timeoutSeconds": .number(20)])
          if stop["reason"] == .string("breakpoint") {
            #expect(stop["pc"]?.stringValue == pc)
            hit = stop
          }
        } catch let error as VMLabError where error.code == .timeout {
          _ = try await debug("halt")
        }
        _ = try await debug("breakpoint_remove", ["address": .string(pc)])
        if hit != nil { break }
      }
      #expect(hit != nil, "no breakpoint at a halted pc was hit again")
      #expect(try await debug("breakpoints")["breakpoints"] == .array([]))

      let stepped = try await debug("step")
      #expect(stepped["reason"] == .string("step"))
      #expect(try await debug("continue")["stopped"] == .bool(false))
      #expect(try await debug("info")["attached"] == .bool(true))
    } catch {
      await debug.close()
      await guest.shutdown()
      throw error
    }
    await debug.close()
    await guest.shutdown()
  }

  /// R-701 Verify as written: x86_64 under `qemu-tcg`, halt at start, read `rip`, break at the
  /// kernel entry from the extracted `System.map`, continue, `wait` stops there.
  /// TODO(R-305, R-310): enable once `images extract-kernel` and the `debian-13-amd64` boot land.
  @Test(.disabled("needs R-305 (System.map from images extract-kernel) and R-310 (x86_64 boot)"))
  func haltAtStartBreakAtKernelEntryX86_64() async throws {}
}
