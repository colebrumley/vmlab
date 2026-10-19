import Darwin
import Foundation
import VMLabCore
import VMLabGDB
import VMLabQEMU

/// The slow probe `qemu_hvf_gdb` (R-702): does QEMU's GDB stub work under HVF on this host?
///
/// It boots a throwaway arm64 `virt` machine under HVF with no disk and no firmware, halted
/// (`-S`), and drives it over `-gdb`: writes a three-instruction loop into RAM (`nop; nop; b`),
/// points `pc` at it and continues; then halts, reads the registers, sets a software breakpoint
/// at the current `pc + 4` (inside the loop), continues and expects the stop there. `yes` keeps
/// `gdb` on `qemu-hvf`; `no` turns it off (Appendix B), and arm64 guests that need `gdb` go to
/// `qemu-tcg`. No QEMU or no HVF here is `unknown`; a stub that misbehaves before the
/// breakpoint is reached is an error, not an answer.
public struct HVFGDBProbe: SlowProbeRunner {
  public let probe = SlowProbe.qemuHVFGDB
  /// Where the loop is written: the start of RAM on `virt`; with the MMU off, also its address.
  static let loop: UInt64 = 0x4000_0000
  /// `nop; nop; b loop` (little endian).
  static let code: [UInt8] = [
    0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5, 0xfe, 0xff, 0xff, 0x17,
  ]

  let installation: QEMUInstallation?
  let stopTimeout: Duration

  public init(installation: QEMUInstallation? = nil, stopTimeout: Duration = .seconds(10)) {
    self.installation = installation
    self.stopTimeout = stopTimeout
  }

  public func run(_ context: SlowProbeContext) async throws(VMLabError) -> ProbeResult {
    guard context.facts.qemu.present, context.facts.qemu.accelerators.contains("hvf") else {
      return .unknown
    }
    let qemu: QEMUInstallation
    if let installation { qemu = installation } else { qemu = try QEMUInstallation.locate() }
    let port = try QEMUMachine.freeLoopbackPort()
    let process = Process()
    process.executableURL = qemu.systemBinary(for: .arm64)
    process.arguments = Self.arguments(port: port)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    do {
      try process.run()
    } catch {
      throw Self.failure("could not start \(qemu.systemBinary(for: .arm64).path): \(error)")
    }
    let result: Result<ProbeResult, VMLabError>
    do throws(VMLabError) {
      let client = try await Self.connect(port: port, process: process, errors: errors)
      defer { Task { await client.close() } }
      result = .success(try await Self.lift { try await exercise(client) })
    } catch {
      result = .failure(error)
    }
    await Self.end(process)
    return try result.get()
  }

  /// Ends QEMU and waits for it off the cooperative pool (`waitUntilExit` blocks its thread).
  static func end(_ process: Process) async {
    guard process.isRunning else { return }
    process.terminate()
    await OffPool.run("vmlab.qemu-hvf-gdb.wait") { process.waitUntilExit() }
  }

  /// The QEMU arguments: arm64 `virt` under HVF, 128 MB, nothing attached, halted, GDB on `port`.
  static func arguments(port: Int) -> [String] {
    [
      "-machine", "virt", "-accel", "hvf", "-cpu", "host", "-m", "128", "-nodefaults",
      "-no-user-config", "-display", "none", "-serial", "none", "-monitor", "none",
      "-gdb", "tcp:127.0.0.1:\(port)", "-S",
    ]
  }

  /// The probe proper, on a connected client of a halted machine.
  func exercise(_ client: GDBClient) async throws -> ProbeResult {
    _ = try await client.haltReason()
    try await client.writeMemory(address: Self.loop, bytes: Self.code)
    try await client.setRegister(named: "pc", value: Self.loop)
    try await client.cont()
    try await Task.sleep(for: .milliseconds(300))
    // Halt the running guest and read where it is.
    let halted = try await client.halt(timeout: .seconds(5))
    _ = try await client.registers()
    guard let pc = try await client.register(named: "pc").uint64 ?? halted.pc,
      (Self.loop..<Self.loop + 12).contains(pc)
    else {
      return .no
    }
    let target = pc + 4 < Self.loop + 12 ? pc + 4 : Self.loop
    do {
      try await client.insertBreakpoint(.software, address: target, kind: 4)
    } catch GDBError.unsupported, GDBError.stubError {
      return .no
    }
    try await client.cont()
    let stop: StopReason
    do {
      stop = try await client.waitForStop(timeout: stopTimeout)
    } catch GDBError.timeout {
      return .no
    }
    let at = try await client.register(named: "pc").uint64 ?? stop.pc
    return at == target ? .yes : .no
  }

  /// Connects to the stub, retrying while QEMU starts; a QEMU that exits first is an error.
  static func connect(port: Int, process: Process, errors: Pipe) async throws(VMLabError)
    -> GDBClient
  {
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
      do {
        return try await GDBClient.connect(
          port: UInt16(port), options: .init(fallbackArchitecture: .arm64))
      } catch {
        if !process.isRunning {
          let reader = errors.fileHandleForReading
          let text = String(
            decoding: await OffPool.run("vmlab.qemu-hvf-gdb.stderr") {
              reader.readDataToEndOfFile()
            }, as: UTF8.self)
          throw failure("QEMU exited (\(process.terminationStatus)): \(text.prefix(400))")
        }
        if ContinuousClock.now > deadline {
          throw failure("the GDB stub on port \(port) did not answer: \(error)")
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  static func lift<T>(_ body: () async throws -> T) async throws(VMLabError) -> T {
    do {
      return try await body()
    } catch let error as VMLabError {
      throw error
    } catch {
      throw failure("\(error)")
    }
  }

  static func failure(_ detail: String) -> VMLabError {
    VMLabError(
      code: .engineError, message: "The qemu_hvf_gdb probe failed: \(detail)",
      hint: "Check the QEMU install (vmlab doctor); the probe stays unknown.",
      data: ["engine": .string("qemu"), "raw": .string(detail)])
  }
}
