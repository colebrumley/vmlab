import Foundation
import VMLabCore

/// `vm_serial`: the guest's serial console through the backend's `SerialChannel` (QEMU's
/// `serial.sock`, or the VZ runner's bridge of the virtio console, R-602). Offsets are byte offsets
/// in the VM's `console.log`, the same in every process and across server restarts; every result
/// returns the one to pass as `since` next.
///
/// `since` defaults to where the VM's current run began in the log (`ConsoleRun`) for `wait` as
/// for `read`, so `wait "login:"` after the prompt was printed still matches, and a prompt from
/// an earlier run does not; pass the last `offset` to wait only for new output, or 0 for every run.
struct VMSerialHandler: ToolHandler {
  /// The most `read` returns at once; `truncated` says there is more.
  static let maxReadBytes = 256 * 1024
  /// The most of the output before a match that `wait` returns as `text`.
  static let maxWaitText = 64 * 1024
  static let maxTail = 10_000
  static let maxTimeoutSeconds = 3600

  var spec: ToolSpec { .vmSerial }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let action = try arguments.string("action") ?? ""
    guard ["read", "tail", "write", "wait"].contains(action) else {
      throw VMLabError.invalidRequest(
        field: "action", reason: "action must be read, tail, write or wait",
        hint: "Pick one of read, tail, write, wait.")
    }
    let since = try arguments.int("since")
    if let since, since < 0 {
      throw VMLabError.invalidRequest(
        field: "since", reason: "since must be 0 or more",
        hint: "Pass the offset a previous vm_serial call returned.")
    }
    let lines = try arguments.int("lines") ?? 50
    guard (1...Self.maxTail).contains(lines) else {
      throw VMLabError.invalidRequest(
        field: "lines", reason: "lines must be between 1 and \(Self.maxTail)",
        hint: "Ask for at most \(Self.maxTail) lines.")
    }
    let text = try arguments.string("text")
    let pattern = try arguments.string("pattern")
    let timeout = try arguments.int("timeoutSeconds") ?? 30
    guard (1...Self.maxTimeoutSeconds).contains(timeout) else {
      throw VMLabError.invalidRequest(
        field: "timeoutSeconds",
        reason: "timeoutSeconds must be between 1 and \(Self.maxTimeoutSeconds)",
        hint: "Wait at most an hour per call; call again to keep waiting.")
    }
    if action == "write", text == nil {
      throw VMLabError.invalidRequest(
        field: "text", reason: "write needs text", hint: "Add text, for example \"root\\n\".")
    }
    if action == "wait", pattern == nil {
      throw VMLabError.invalidRequest(
        field: "pattern", reason: "wait needs pattern",
        hint: "Add pattern, a regular expression such as \"login:\".")
    }

    let name = try arguments.string("vm") ?? ""
    if action == "write" {
      // Only a live guest takes input: `wrong_state`, with the hint to start it, otherwise.
      let vm = try await context.manager.attach(name)
      let serial = try vm.channel(.serial)
      let offset = try await LongOperation.typed("vm_serial write", vm: vm.id) {
        try await serial.write(text ?? "")
      }
      return ToolResult(
        ["text": .string(""), "offset": .number(Double(offset)), "truncated": .bool(false)])
    }
    if action == "wait" { try SerialChannel.validate(pattern: pattern ?? "") }
    let request = Request(
      action: action, since: since, lines: lines, pattern: pattern ?? "", timeout: timeout)
    let console: SerialConsole
    do {
      console = try await context.manager.serialConsole(name)
    } catch let error where error.code == .guestUnreachable {
      // The engine exited ahead of the record (a power-off): then the log is the record.
      let record = try context.store.find(name)
      guard try await engineExited(record.id, within: .zero, context: context) else { throw error }
      console = .log(record, context.store.directory(of: record.id).appending(path: "console.log"))
    }
    switch console {
    case .live(let vm, let serial):
      return try await live(vm, serial, request, context: context)
    case .log(let record, let log):
      return try await stopped(record.id, log: log, request, context: context)
    }
  }

  /// A read, tail or wait's arguments.
  struct Request {
    var action: String
    var since: Int?
    var lines: Int
    var pattern: String
    var timeout: Int
  }

  /// How long a wait whose channel ended looks for the engine to exit before it is
  /// `guest_unreachable`, and how often it looks.
  var exitGrace: Duration = .seconds(3)
  var exitPoll: Duration = .milliseconds(100)
  /// Whether the engine process `pid` still runs the VM in the directory.
  var engineIsRunning: @Sendable (Int32, URL) -> Bool = {
    EngineProcess.isRunning($0, vmDirectory: $1)
  }

  /// A running or paused VM: the channel answers, and a wait whose output ends without a match
  /// (the guest powered off or was killed) answers from the log once the engine is gone.
  func live(
    _ vm: any RunningVM, _ serial: SerialChannel, _ request: Request, context: ToolContext
  ) async throws(VMLabError) -> ToolResult {
    // The log spans every run; by default only this run's output counts.
    let from =
      request.since.map(UInt64.init)
      ?? ConsoleRun.start(vmDirectory: context.store.directory(of: vm.id))
    switch request.action {
    case "read":
      return Self.result(await serial.read(since: from, maxBytes: Self.maxReadBytes))
    case "tail":
      return Self.result(await serial.read(tail: request.lines))
    default:
      let ended: VMLabError
      do {
        let outcome = try await context.progress.during(
          "waiting for \(request.pattern) on the serial console", every: context.heartbeat
        ) { () throws(VMLabError) in
          try await LongOperation.typed("vm_serial wait", vm: vm.id) {
            try await serial.waitOrEnd(
              for: request.pattern, since: from, timeout: .seconds(request.timeout))
          }
        }
        switch outcome {
        case .matched(let match):
          return await Self.matched(match, serial: serial, from: from)
        case .ended:
          ended = VMLabError(
            code: .guestUnreachable, message: "The serial channel of VM \(vm.id) stopped reading.",
            hint: "The engine is still running; check the VM with vm_inspect, or wait again.",
            data: ["vm": .string(vm.id)])
        }
      } catch let error where error.code == .guestUnreachable {
        // The backend closed the channel (a kill, the engine's exit): the same as its end.
        ended = error
      }
      // The record flips to stopped later (the event watcher, a settle), so look at the engine.
      guard try await engineExited(vm.id, within: exitGrace, context: context) else { throw ended }
      // The log is final now: scan it all again from `from`, so anchors keep their context.
      return try await stopped(
        vm.id, log: context.store.directory(of: vm.id).appending(path: "console.log"), request,
        from: from, context: context)
    }
  }

  /// Whether the VM's engine process is gone or its record no longer live, checking every
  /// `exitPoll` for up to `grace` (once, for zero).
  func engineExited(_ id: String, within grace: Duration, context: ToolContext)
    async throws(VMLabError) -> Bool
  {
    let directory = context.store.directory(of: id)
    let deadline = ContinuousClock.now + grace
    while true {
      let record = try context.store.find(id)
      if !record.state.isLive { return true }
      if let pid = record.runtime?.pid, !engineIsRunning(pid, directory) { return true }
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: exitPoll)
      try LongOperation.checkCancellation("vm_serial wait", vm: id)
    }
  }

  /// A VM that is not running: the console log is the record. With no log yet, nothing was
  /// printed. A wait scans from `from` (default: `since`'s) and, with no match, returns at once
  /// with `stopped: true` and the last of the text.
  func stopped(
    _ id: String, log: URL, _ request: Request, from: UInt64? = nil, context: ToolContext
  ) async throws(VMLabError) -> ToolResult {
    let from =
      from ?? request.since.map(UInt64.init)
      ?? ConsoleRun.start(vmDirectory: context.store.directory(of: id))
    let serial = SerialChannel(
      socketPath: "", logURL: log.deletingLastPathComponent().appending(path: "serial.log"),
      consoleLog: log)
    let opened = try await LongOperation.typed("vm_serial \(request.action)", vm: id) {
      try await serial.openLog()
    }
    guard opened else {
      var result: [String: JSONValue] = [
        "text": .string(""), "offset": .number(0), "truncated": .bool(false),
      ]
      if request.action == "wait" { result["stopped"] = .bool(true) }
      return ToolResult(result)
    }
    do {
      let result = try await Self.answer(request, from: from, log: serial, vm: id)
      await serial.stop()
      return result
    } catch {
      await serial.stop()
      throw error
    }
  }

  /// `stopped`'s answer from the opened log.
  static func answer(
    _ request: Request, from: UInt64, log serial: SerialChannel, vm id: String
  ) async throws(VMLabError) -> ToolResult {
    switch request.action {
    case "read":
      return Self.result(await serial.read(since: from, maxBytes: Self.maxReadBytes))
    case "tail":
      return Self.result(await serial.read(tail: request.lines))
    default:
      let outcome = try await LongOperation.typed("vm_serial wait", vm: id) {
        try await serial.waitOrEnd(
          for: request.pattern, since: from, timeout: .seconds(request.timeout))
      }
      switch outcome {
      case .matched(let match):
        return await Self.matched(match, serial: serial, from: from)
      case .ended(let end):
        // As a timed-out wait: the last of the output since `from`.
        let cap = SerialChannel.timeoutTextBytes
        let start = max(from, end > cap ? end - cap : 0)
        let seen = await serial.read(since: start)
        return ToolResult([
          "text": .string(seen.text), "offset": .number(Double(end)),
          "truncated": .bool(start > from), "stopped": .bool(true),
        ])
      }
    }
  }

  /// A wait's match: the output from `from` up to the end of the match, at most maxWaitText of it.
  static func matched(_ match: SerialMatch, serial: SerialChannel, from: UInt64) async
    -> ToolResult
  {
    let cap = UInt64(Self.maxWaitText)
    let start = min(max(from, match.offset > cap ? match.offset - cap : 0), match.offset)
    let before = await serial.read(since: start, maxBytes: Int(match.offset - start))
    return ToolResult([
      "text": .string(before.text), "offset": .number(Double(match.offset)),
      "matched": .string(match.match), "truncated": .bool(before.start > from),
    ])
  }

  static func result(_ read: SerialRead) -> ToolResult {
    ToolResult([
      "text": .string(read.text), "offset": .number(Double(read.offset)),
      "truncated": .bool(read.truncated),
    ])
  }
}
