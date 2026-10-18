import Foundation
import VMLabCore

/// `vm_debug`: the guest CPU through its GDB stub (R-701). The connection belongs to this process's
/// `DebugSessions` (R-705), not to the call: the first action that needs the stub connects (QEMU
/// stops the guest when a debugger connects), later calls reuse it, and a lost connection is
/// reopened with every recorded breakpoint inserted again.
struct VMDebugHandler: ToolHandler {
  /// The most `read_memory` returns, and `write_memory` takes, in one call.
  static let maxBytes = 64 * 1024
  /// Up to this many bytes, `read_memory` adds an ASCII column.
  static let asciiLimit = 256

  var spec: ToolSpec { .vmDebug }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let action = try arguments.string("action") ?? ""
    guard Self.actions.contains(action) else {
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(action) is not a vm_debug action",
        hint: "Use one of: \(Self.actions.joined(separator: ", ")).")
    }
    let record = try context.store.find(try arguments.string("vm") ?? "")
    let running = try await context.manager.attach(record.id)
    let endpoint = try running.channel(.gdb)
    let session = try await context.debug.session(
      vm: record.id, endpoint: endpoint, arch: record.guest.arch,
      directory: context.store.directory(of: record.id))
    if let symbolFile = try arguments.string("symbolFile") {
      try await session.setSymbolFile(symbolFile.isEmpty ? nil : symbolFile)
    }
    let thread = try arguments.string("thread")

    var result: [String: JSONValue] = [:]
    switch action {
    case "info":
      result = await Self.info(session, endpoint: endpoint)
    case "halt":
      result = Self.render(try await session.halt())
    case "continue":
      try await session.resume(thread: thread)
      result["stopped"] = .bool(false)
    case "step":
      result = Self.render(try await session.step(thread: thread))
    case "wait":
      let seconds = try arguments.int("timeoutSeconds") ?? 30
      result = Self.render(try await session.wait(timeout: .seconds(max(seconds, 0))))
    case "breakpoint_add":
      let point = try Self.point(arguments)
      result["breakpoints"] = Self.render(try await session.add(point))
    case "breakpoint_remove":
      let point = try Self.point(arguments)
      result["breakpoints"] = Self.render(
        try await session.remove(address: point.address, kind: point.kind))
    case "breakpoints":
      result["breakpoints"] = Self.render(await session.points)
    case "registers":
      let registers = try await session.registers(thread: thread)
      var object: [String: JSONValue] = [:]
      for register in registers {
        object[register.name] = register.value.map { .string($0) } ?? .null
      }
      result["registers"] = .object(object)
      result["stopped"] = .bool(true)
      if let pc = registers.first(where: { $0.name == "pc" || $0.name == "rip" })?.value,
        let value = Self.parseAddress(pc)
      {
        result["pc"] = .string(Self.hex(value))
      }
    case "read_memory":
      let address = try Self.address(arguments)
      guard let size = try arguments.int("size"), (1...Self.maxBytes).contains(size) else {
        throw VMLabError.invalidRequest(
          field: "size", reason: "read_memory needs size between 1 and \(Self.maxBytes)",
          hint: "Add size: the number of bytes to read.")
      }
      let bytes = try await session.readMemory(address: address, length: size, thread: thread)
      result["address"] = .string(Self.hex(address))
      result["size"] = .number(Double(bytes.count))
      result["bytes"] = .string(Self.hexBytes(bytes))
      if bytes.count <= Self.asciiLimit { result["ascii"] = .string(Self.ascii(bytes)) }
    case "write_memory":
      let address = try Self.address(arguments)
      let bytes = try Self.data(arguments)
      try await session.writeMemory(address: address, bytes: bytes, thread: thread)
      result["address"] = .string(Self.hex(address))
      result["size"] = .number(Double(bytes.count))
    default:
      break
    }
    if result["stopped"] == nil {
      result["stopped"] = await session.running().map { .bool(!$0) } ?? .null
    }
    result["endpoint"] = .string(endpoint.address)
    result["attached"] = .bool(await session.attached)
    result["vm"] = .object(["id": .string(record.id), "name": .string(record.name)])
    return ToolResult(result)
  }

  static let actions = [
    "info", "halt", "continue", "step", "wait", "breakpoint_add", "breakpoint_remove",
    "breakpoints", "registers", "read_memory", "write_memory",
  ]

  // MARK: info

  static func info(_ session: DebugSession, endpoint: GDBEndpoint) async -> [String: JSONValue] {
    let symbolFile = await session.symbolFile
    let attached = await session.attached
    let busy = await session.busySince
    let file = symbolFile.map { " " + shellQuote($0) } ?? ""
    var result: [String: JSONValue] = [
      "breakpoints": render(await session.points),
      "connect": .object([
        "gdb": .string("gdb\(file) -ex 'target remote \(endpoint.address)'"),
        "lldb": .string("lldb\(file) -o 'gdb-remote \(endpoint.address)'"),
      ]),
      "note": .string(
        attached
          ? "vmlab holds the stub's only connection; a human debugger can attach once this "
            + "vmlab server exits"
          : busy != nil
            ? "another debugger (a human's gdb or lldb, or another vmlab server) holds the "
              + "stub; vm_debug actions answer debug_busy until it detaches"
            : "vmlab is not attached; the next vm_debug action connects (QEMU stops the guest "
              + "when a debugger connects) unless another debugger holds the stub (debug_busy)"),
    ]
    result["symbolFile"] = symbolFile.map { .string($0) } ?? .null
    return result
  }

  // MARK: Arguments

  static func address(_ arguments: ToolArguments) throws(VMLabError) -> UInt64 {
    guard let text = try arguments.string("address") else {
      throw VMLabError.invalidRequest(
        field: "address", reason: "this action needs an address",
        hint: "Add address in 0x hex, e.g. 0xffff800010000000.")
    }
    guard let value = parseAddress(text) else {
      throw VMLabError.invalidRequest(
        field: "address", reason: "\(text) is not an address",
        hint: "Give a number in 0x hex (0xffff800010000000) or decimal; symbols are not resolved.")
    }
    return value
  }

  /// `0x` hex, or decimal digits.
  static func parseAddress(_ text: String) -> UInt64? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
    if trimmed.lowercased().hasPrefix("0x") { return UInt64(trimmed.dropFirst(2), radix: 16) }
    return UInt64(trimmed, radix: 10)
  }

  static func point(_ arguments: ToolArguments) throws(VMLabError) -> DebugPoint {
    let address = try address(arguments)
    let kindName = try arguments.string("kind") ?? DebugPointKind.software.rawValue
    guard let kind = DebugPointKind(rawValue: kindName) else {
      throw VMLabError.invalidRequest(
        field: "kind", reason: "\(kindName) is not a stop point kind",
        hint: "Use software, hardware, watch_write, watch_read or watch_access.")
    }
    var size: Int?
    if kind.isWatchpoint {
      size = try arguments.int("size") ?? 1
      guard let size, [1, 2, 4, 8].contains(size) else {
        throw VMLabError.invalidRequest(
          field: "size", reason: "a watchpoint watches 1, 2, 4 or 8 bytes",
          hint: "Set size to 1, 2, 4 or 8.")
      }
    }
    return DebugPoint(address: address, kind: kind, size: size)
  }

  static func data(_ arguments: ToolArguments) throws(VMLabError) -> [UInt8] {
    guard var text = try arguments.string("data") else {
      throw VMLabError.invalidRequest(
        field: "data", reason: "write_memory needs data",
        hint: "Add data: the bytes as hex, e.g. 1f2003d5.")
    }
    text = text.replacingOccurrences(of: " ", with: "")
    if text.lowercased().hasPrefix("0x") { text = String(text.dropFirst(2)) }
    guard !text.isEmpty, text.count % 2 == 0, text.count / 2 <= maxBytes else {
      throw VMLabError.invalidRequest(
        field: "data",
        reason: "data must be an even number of hex digits, at most \(maxBytes) bytes",
        hint: "Give the bytes as hex, two digits each, in memory order.")
    }
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2)
      guard let byte = UInt8(text[index..<next], radix: 16) else {
        throw VMLabError.invalidRequest(
          field: "data", reason: "data has a non-hex digit",
          hint: "Give the bytes as hex, two digits each.")
      }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  // MARK: Rendering

  static func render(_ stop: DebugStop) -> [String: JSONValue] {
    var result: [String: JSONValue] = [
      "stopped": .bool(true), "reason": .string(stop.reason.rawValue),
      "signal": .number(Double(stop.signal)),
    ]
    if let pc = stop.pc { result["pc"] = .string(hex(pc)) }
    if let thread = stop.thread { result["thread"] = .string(thread) }
    if let address = stop.watchAddress { result["watchAddress"] = .string(hex(address)) }
    return result
  }

  static func render(_ points: [DebugPoint]) -> JSONValue {
    .array(
      points.map { point in
        var object: [String: JSONValue] = [
          "address": .string(hex(point.address)), "kind": .string(point.kind.rawValue),
        ]
        if let size = point.size { object["size"] = .number(Double(size)) }
        return .object(object)
      })
  }

  static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

  static func hexBytes(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      out.append(digits[Int(byte >> 4)])
      out.append(digits[Int(byte & 0xf)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Printable ASCII as itself, every other byte as `.`.
  static func ascii(_ bytes: [UInt8]) -> String {
    String(
      decoding: bytes.map { (0x20..<0x7f).contains($0) ? $0 : UInt8(ascii: ".") }, as: UTF8.self)
  }

  static func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
