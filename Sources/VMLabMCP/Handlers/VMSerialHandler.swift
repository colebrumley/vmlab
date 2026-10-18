import Foundation
import VMLabCore

/// `vm_serial`: the guest's serial console through the backend's `SerialChannel` (QEMU's
/// `serial.sock`, or the VZ runner's bridge of the virtio console, R-602). Offsets are byte offsets
/// in the channel's buffer; every result returns the one to pass as `since` next.
///
/// `since` defaults to the start of the buffer for `wait` as for `read`, so `wait "login:"` after
/// the prompt was printed still matches; pass the last `offset` to wait only for new output.
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

    let vm = try await context.manager.attach(try arguments.string("vm") ?? "")
    let serial = try vm.channel(.serial)
    let from = UInt64(since ?? 0)
    switch action {
    case "read":
      return Self.result(await serial.read(since: from, maxBytes: Self.maxReadBytes))
    case "tail":
      return Self.result(await serial.read(tail: lines))
    case "write":
      let offset = try await LongOperation.typed("vm_serial write", vm: vm.id) {
        try await serial.write(text ?? "")
      }
      return ToolResult(
        ["text": .string(""), "offset": .number(Double(offset)), "truncated": .bool(false)])
    default:
      let match = try await context.progress.during(
        "waiting for \(pattern ?? "") on the serial console", every: context.heartbeat
      ) { () throws(VMLabError) in
        try await LongOperation.typed("vm_serial wait", vm: vm.id) {
          try await serial.wait(for: pattern ?? "", since: from, timeout: .seconds(timeout))
        }
      }
      // The output from since up to the end of the match, at most maxWaitText of it.
      let cap = UInt64(Self.maxWaitText)
      let start = min(max(from, match.offset > cap ? match.offset - cap : 0), match.offset)
      let before = await serial.read(since: start, maxBytes: Int(match.offset - start))
      return ToolResult([
        "text": .string(before.text), "offset": .number(Double(match.offset)),
        "matched": .string(match.match), "truncated": .bool(before.start > from),
      ])
    }
  }

  static func result(_ read: SerialRead) -> ToolResult {
    ToolResult([
      "text": .string(read.text), "offset": .number(Double(read.offset)),
      "truncated": .bool(read.truncated),
    ])
  }
}
