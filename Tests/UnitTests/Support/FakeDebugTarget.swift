import Foundation
import Synchronization
import VMLabCore

/// A `DebugTarget` with a scripted CPU: registers `pc`/`sp`, 4 KB of memory at 0x1000, stop points
/// recorded as inserted. `resume` runs until `stopNext` (or a halt) delivers a stop.
final class FakeDebugTarget: DebugTarget {
  struct State {
    var running = false
    var connected = true
    var pc: UInt64 = 0x4008_0000
    var memory = [UInt8](repeating: 0, count: 4096)
    var inserted: [DebugPoint] = []
    var log: [String] = []
    var pendingStop: DebugStop?
  }

  let state = Mutex(State())

  var log: [String] { state.withLock { $0.log } }
  var inserted: [DebugPoint] { state.withLock { $0.inserted } }

  /// Makes the running CPU stop with `stop` (seen by the next `waitForStop`).
  func stopNext(_ stop: DebugStop) {
    state.withLock {
      $0.pendingStop = stop
      if let pc = stop.pc { $0.pc = pc }
    }
  }

  func hangUp() { state.withLock { $0.connected = false } }

  var isRunning: Bool { get async { state.withLock { $0.running } } }
  var isConnected: Bool { get async { state.withLock { $0.connected } } }

  private func check(_ what: String) throws(VMLabError) {
    let connected = state.withLock {
      $0.log.append(what)
      return $0.connected
    }
    guard connected else {
      throw VMLabError(code: .guestUnreachable, message: "closed", hint: "")
    }
  }

  func halt(timeout: Duration) async throws(VMLabError) -> DebugStop {
    try check("halt")
    return state.withLock {
      let signal = $0.running ? 2 : 5
      $0.running = false
      $0.pendingStop = nil
      return DebugStop(reason: .signal, signal: signal, thread: "p01.01", pc: $0.pc)
    }
  }

  func resume(thread: String?) async throws(VMLabError) {
    try check("resume" + (thread.map { ":" + $0 } ?? ""))
    state.withLock { $0.running = true }
  }

  func step(thread: String?) async throws(VMLabError) {
    try check("step")
    state.withLock {
      $0.pc += 4
      $0.pendingStop = DebugStop(reason: .signal, signal: 5, thread: "p01.01", pc: $0.pc)
      $0.running = true
    }
  }

  func waitForStop(timeout: Duration) async throws(VMLabError) -> DebugStop {
    try check("wait")
    let stop: DebugStop? = state.withLock {
      if let stop = $0.pendingStop {
        $0.pendingStop = nil
        $0.running = false
        return stop
      }
      return $0.running ? nil : DebugStop(reason: .signal, signal: 5, pc: $0.pc)
    }
    guard let stop else {
      throw VMLabError(
        code: .timeout, message: "no stop", hint: "", data: ["timeoutSeconds": .number(0)])
    }
    return stop
  }

  func insert(_ point: DebugPoint) async throws(VMLabError) {
    try check("insert \(point.kind.rawValue) \(String(point.address, radix: 16))")
    let running = state.withLock { $0.running }
    if running { throw VMLabError(code: .wrongState, message: "running", hint: "") }
    state.withLock { $0.inserted.append(point) }
  }

  func remove(_ point: DebugPoint) async throws(VMLabError) {
    try check("remove \(point.kind.rawValue) \(String(point.address, radix: 16))")
    state.withLock { $0.inserted.removeAll { $0.matches(point) } }
  }

  func registers(thread: String?) async throws(VMLabError) -> [DebugRegister] {
    try check("registers")
    let pc = state.withLock { $0.pc }
    return [
      DebugRegister(name: "pc", value: "0x" + String(pc, radix: 16)),
      DebugRegister(name: "sp", value: "0xffff00008000fff0"),
      DebugRegister(name: "v0", value: nil),
    ]
  }

  func readMemory(address: UInt64, length: Int, thread: String?) async throws(VMLabError)
    -> [UInt8]
  {
    try check("read")
    return try state.withLock { s throws(VMLabError) in
      guard address >= 0x1000, address + UInt64(length) <= 0x2000 else {
        throw VMLabError(code: .engineError, message: "E14", hint: "")
      }
      let start = Int(address - 0x1000)
      return Array(s.memory[start..<start + length])
    }
  }

  func writeMemory(address: UInt64, bytes: [UInt8], thread: String?) async throws(VMLabError) {
    try check("write")
    state.withLock { s in
      let start = Int(address - 0x1000)
      s.memory.replaceSubrange(start..<start + bytes.count, with: bytes)
    }
  }

  func close() async { state.withLock { $0.connected = false } }
}

/// Hands out `FakeDebugTarget`s, one per connect, and counts the connects.
final class FakeDebugConnector: DebugConnector {
  let state = Mutex<(targets: [FakeDebugTarget], busy: Bool)>(([], false))

  var targets: [FakeDebugTarget] { state.withLock { $0.targets } }
  var latest: FakeDebugTarget? { targets.last }

  /// Makes every later connect fail with `debug_busy`.
  func setBusy(_ busy: Bool) { state.withLock { $0.busy = busy } }

  func connect(to endpoint: GDBEndpoint, arch: GuestSpec.Arch) async throws(VMLabError)
    -> any DebugTarget
  {
    try state.withLock { s throws(VMLabError) -> FakeDebugTarget in
      if s.busy {
        throw VMLabError(
          code: .debugBusy, message: "busy", hint: "",
          data: ["endpoint": .string(endpoint.address)])
      }
      let target = FakeDebugTarget()
      s.targets.append(target)
      return target
    }
  }
}
