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
      var context = ToolContext(
        home: guest.home, backends: guest.backends, startGate: IntegrationAdmission.gate)
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

  /// R-701, arm64 variant: a `debian-13-arm64`
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

  /// R-701 Verify: `debian-13-amd64` under `qemu-tcg` with `boot.haltAtStart`, booted from its
  /// extracted kernel (R-305) with `nokaslr`: halt at the reset vector, read `rip`, break at the
  /// kernel entry, continue, and `wait` stops there. Debian ships a placeholder `System.map`
  /// (the real one is in the -dbg package), so the entry is `start_kernel` when the map has it
  /// and otherwise the bzImage header's `code32_start`, where the setup code enters the kernel.
  static func kernelEntry(_ files: KernelFiles) throws -> String {
    if let url = files.systemMap, let map = try? String(contentsOf: url, encoding: .utf8),
      let line = map.split(separator: "\n").first(where: { $0.hasSuffix(" T start_kernel") })
    {
      return "0x" + line.prefix { $0 != " " }
    }
    let kernel = try Data(contentsOf: files.kernel)
    try #require(kernel.count > 0x218 && kernel[0x202..<0x206] == Data("HdrS".utf8))
    let start = kernel[0x214..<0x218].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return "0x" + String(start, radix: 16)
  }

  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(6)))
  func haltAtStartBreakAtKernelEntryX86_64() async throws {
    let images = ImageStore(
      home: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vmlab"))
    let files = try await images.extractKernel("debian-13-amd64")
    let entry = try Self.kernelEntry(files)
    let guest = try await QEMUGuest.boot(
      features: [.serial, .gdb, .directKernelBoot, .haltAtStart, .netNAT], memoryGB: 1,
      boot: BootSpec(
        mode: .kernel, cmdline: "console=ttyS0 root=/dev/vda1 nokaslr", haltAtStart: true),
      profile: .qemuTCG, guest: GuestSpec(os: .linux, arch: .x86_64), image: "debian-13-amd64")
    let debug = Debugger(guest)
    do {
      let halted = try await debug("halt")
      #expect(halted["stopped"] == .bool(true))
      let registers = try await debug("registers")
      let rip = try #require(registers["registers"]?["rip"]?.stringValue)
      #expect(UInt64(rip.dropFirst(2), radix: 16) == 0xfff0, "rip at reset: \(rip)")

      _ = try await debug("breakpoint_add", ["address": .string(entry)])
      #expect(try await debug("continue")["stopped"] == .bool(false))
      let stop = try await debug("wait", ["timeoutSeconds": .number(240)])
      #expect(stop["reason"] == .string("breakpoint"))
      #expect(
        stop["pc"]?.stringValue.flatMap { UInt64($0.dropFirst(2), radix: 16) }
          == UInt64(entry.dropFirst(2), radix: 16))
    } catch {
      await debug.close()
      await guest.shutdown()
      throw error
    }
    await debug.close()
    await guest.shutdown()
  }

  /// R-703 Verify: `boot.haltAtStart` under `qemu-hvf` (arm64, EDK2 from the disk): the CPU waits
  /// at its reset pc, `continue` lets the firmware print on serial, and `vm_lifecycle reset`
  /// returns it to that first instruction, halted, with its breakpoint kept and still hit.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(4)))
  func haltAtStartAndResetKeepBreakpoints() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .gdb, .haltAtStart, .netNAT], memoryGB: 1,
      boot: BootSpec(haltAtStart: true))
    let debug = Debugger(guest)
    do {
      #expect(try await guest.machine.status().running == false)
      let reset = try #require(try await debug("registers")["pc"]?.stringValue)
      #expect(try await guest.machine.serial.read(since: 0).text.isEmpty)

      // The next instruction after the reset pc, as a hardware breakpoint (the flash is ROM).
      let next = try #require(try await debug("step")["pc"]?.stringValue)
      _ = try await debug(
        "breakpoint_add", ["address": .string(next), "kind": .string("hardware")])
      _ = try await debug(
        "breakpoint_remove", ["address": .string(next), "kind": .string("hardware")])
      #expect(try await debug("continue")["stopped"] == .bool(false))
      _ = try await guest.machine.serial.wait(
        for: "BdsDxe|UEFI|GRUB|Booting", since: 0, timeout: .seconds(60))

      _ = try await debug(
        "breakpoint_add", ["address": .string(next), "kind": .string("hardware")])
      let lifecycle = try await ToolHandlers.call(
        "vm_lifecycle",
        arguments: .object(["vm": .string(guest.record.id), "action": .string("reset")]),
        context: debug.context)
      #expect(lifecycle.warnings.isEmpty)
      let halted = try await debug("halt")
      #expect(halted["pc"]?.stringValue == reset)
      #expect(try await debug("registers")["pc"]?.stringValue == reset)
      #expect(try await debug("breakpoints")["breakpoints"]?.arrayValue?.count == 1)
      _ = try await debug("continue")
      let hit = try await debug("wait", ["timeoutSeconds": .number(10)])
      #expect(hit["reason"] == .string("breakpoint"))
      #expect(hit["pc"]?.stringValue == next)
    } catch {
      await debug.close()
      await guest.shutdown()
      throw error
    }
    await debug.close()
    await guest.shutdown()
  }

  /// R-704 Verify: under `qemu-tcg`, an access watchpoint on the halted CPU's stack (8 bytes at
  /// `sp`) stops the guest with reason `watchpoint` and the watched address. A frame the CPU does
  /// not touch again is retried at the next halt.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(6)))
  func stackWatchpointStopsUnderTCG() async throws {
    let guest = try await QEMUGuest.boot(
      features: [.serial, .gdb, .netNAT], memoryGB: 1, profile: .qemuTCG)
    let debug = Debugger(guest)
    do {
      _ = try await guest.machine.serial.wait(
        for: "Linux version|EFI stub", since: 0, timeout: .seconds(120))
      var hit: JSONValue?
      for _ in 0..<6 {
        _ = try await debug("halt")
        let sp = try #require(try await debug("registers")["registers"]?["sp"]?.stringValue)
        let address = try #require(UInt64(sp.dropFirst(2), radix: 16))
        let watch: [String: JSONValue] = [
          "address": .string("0x" + String(address, radix: 16)), "kind": .string("watch_access"),
          "size": .number(8),
        ]
        let added = try await debug("breakpoint_add", watch)
        #expect(added["breakpoints"]?.arrayValue?.first?["kind"] == .string("watch_access"))
        _ = try await debug("continue")
        do {
          let stop = try await debug("wait", ["timeoutSeconds": .number(20)])
          if stop["reason"] == .string("watchpoint") {
            #expect(
              stop["watchAddress"]?.stringValue.flatMap { UInt64($0.dropFirst(2), radix: 16) }
                == address)
            hit = stop
          }
        } catch let error as VMLabError where error.code == .timeout {
          _ = try await debug("halt")
        }
        var remove = watch
        remove["size"] = nil
        _ = try await debug("breakpoint_remove", remove)
        if hit != nil { break }
      }
      #expect(hit != nil, "no watchpoint on a halted stack was hit")
      _ = try await debug("continue")
    } catch {
      await debug.close()
      await guest.shutdown()
      throw error
    }
    await debug.close()
    await guest.shutdown()
  }
}
