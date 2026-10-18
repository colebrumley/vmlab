import Foundation
import VMLabCore

/// `vm_introspect` over QMP (R-311): the named queries map to `query-status`, `query-block`,
/// `query-pci`, `query-cpus-fast` (JSON) and to the HMP commands `info mtree`, `info registers -a`
/// and `info qtree` (text, through `human-monitor-command`). Raw commands are allowed only when
/// read-only: QMP `query-*`, HMP `info ...`.
struct QMPIntrospection: Introspection {
  let qmp: QMPClient

  func query(_ query: IntrospectionQuery) async throws(VMLabError) -> IntrospectionAnswer {
    switch query {
    case .status: return .json(try await execute("query-status"))
    case .block: return .json(try await execute("query-block"))
    case .pci: return .json(try await execute("query-pci"))
    case .cpus: return .json(try await execute("query-cpus-fast"))
    case .memoryTree: return .text(try await hmp("info mtree"))
    case .registers: return .text(try await hmp("info registers -a"))
    case .devices: return .text(try await hmp("info qtree"))
    case .qmp(let command):
      try Self.checkQMP(command)
      return .json(try await execute(command))
    case .hmp(let command):
      let normalized = try Self.checkHMP(command)
      return .text(try await hmp(normalized))
    }
  }

  private func execute(_ command: String) async throws(VMLabError) -> JSONValue {
    try await QEMUBackend.lift { try await qmp.execute(command) }
  }

  private func hmp(_ commandLine: String) async throws(VMLabError) -> String {
    let reply = try await QEMUBackend.lift {
      try await qmp.execute(
        "human-monitor-command", arguments: ["command-line": .string(commandLine)])
    }
    return reply.stringValue ?? ""
  }

  /// `query-` and lowercase letters, digits and dashes.
  static func checkQMP(_ command: String) throws(VMLabError) {
    let name = command.dropFirst("query-".count)
    guard command.hasPrefix("query-"), !name.isEmpty,
      name.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" })
    else {
      throw VMLabError.invalidRequest(
        field: "qmp", reason: "only read-only QMP query-* commands are allowed, not \(command)",
        hint: "Use a query-* command such as query-chardev, or one of the named queries.")
    }
  }

  /// `info` and space-separated words of letters, digits and `_ - . , = :`; anything else (a
  /// newline, `;`) is refused. Returns the command with its spaces collapsed.
  static func checkHMP(_ command: String) throws(VMLabError) -> String {
    let words = command.split(separator: " ")
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.,=:")
    guard words.count >= 2, words[0] == "info",
      words.dropFirst().allSatisfy({ $0.allSatisfy(allowed.contains) })
    else {
      throw VMLabError.invalidRequest(
        field: "hmp", reason: "only read-only HMP info commands are allowed, not \(command)",
        hint: "Use an info command such as info mtree, or one of the named queries.")
    }
    return words.joined(separator: " ")
  }
}

/// `vm_memory_dump` over QMP (R-311): `pmemsave` for a range (raw bytes), `dump-guest-memory`
/// for all of memory (an ELF core, no paging). QEMU writes the file; its size is read back.
struct QMPMemoryDumper: MemoryDumper {
  let qmp: QMPClient
  var timeout: Duration = .seconds(600)

  func dump(_ request: MemoryDumpRequest) async throws(VMLabError) -> MemoryDumpResult {
    let path = request.path.path
    switch (request.address, request.size) {
    case (let address?, let size?):
      // JSON numbers are doubles: QMP integers above 2^53 would lose bits.
      guard address < 1 << 53, size < 1 << 53, address &+ size >= address else {
        throw VMLabError.invalidRequest(
          field: "address", reason: "the range does not fit guest physical addresses",
          hint: "Use an address and size below 2^53.")
      }
      try await QEMUBackend.lift {
        try await qmp.execute(
          "pmemsave",
          arguments: [
            "val": .number(Double(address)), "size": .number(Double(size)),
            "filename": .string(path),
          ], timeout: timeout)
      }
    case (nil, nil):
      try await QEMUBackend.lift {
        try await qmp.execute(
          "dump-guest-memory",
          arguments: [
            "paging": .bool(false), "protocol": .string("file:\(path)"), "format": .string("elf"),
          ], timeout: timeout)
      }
    default:
      throw VMLabError.invalidRequest(
        field: request.address == nil ? "address" : "size",
        reason: "a range needs both address and size",
        hint: "Pass both for a raw range, or neither for a full ELF dump.")
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    guard let bytes = (attributes?[.size] as? NSNumber)?.uint64Value else {
      throw VMLabError(
        code: .engineError, message: "QEMU reported success but wrote no file at \(path).",
        hint: "See qemu.log in the VM directory.", data: ["engine": .string("qemu")])
    }
    return MemoryDumpResult(path: request.path, bytes: bytes, format: request.format)
  }
}
