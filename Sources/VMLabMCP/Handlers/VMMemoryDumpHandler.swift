import Foundation
import VMLabCore

/// `vm_memory_dump`: guest physical memory to a file under `<vm>/dumps/`, or at the host path
/// `local`, through the VM's `memory_dump` channel. A range is raw bytes
/// (`<time>-<address>-<size>.raw`); no range is the whole memory as an ELF core (`<time>.elf`).
/// A range over 256 MB needs `confirm: true`.
///
/// `local` is a host write the model names, checked exactly as `vm_file pull`'s
/// (`LocalDestination`, the write side of `PathPolicy`) before the engine is asked: an existing
/// directory receives the default name, an existing file is replaced. The engine writes
/// `<final>.part` in a staging folder under `<vm>/dumps/`, which the handler renames into the
/// checked directory (as a pull stages in `<vm>/pulled/`), so a partial dump never has the final
/// name, the engine never writes through a path a symlink could redirect, and a symlink planted
/// at the final name is replaced, not followed.
struct VMMemoryDumpHandler: ToolHandler {
  static let confirmAbove: UInt64 = 256 << 20

  var spec: ToolSpec { .vmMemoryDump }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let address = try Self.address(try arguments.string("address"))
    let size = try arguments.int("size").map { size throws(VMLabError) -> UInt64 in
      guard size > 0 else {
        throw VMLabError.invalidRequest(
          field: "size", reason: "size must be at least 1", hint: "Pass a positive byte count.")
      }
      return UInt64(size)
    }
    if (address == nil) != (size == nil) {
      throw VMLabError.invalidRequest(
        field: address == nil ? "address" : "size", reason: "a range needs both address and size",
        hint: "Pass both for a raw range, or neither for a full ELF dump.")
    }
    if let size, size > Self.confirmAbove, !(try arguments.bool("confirm")) {
      throw VMLabError(
        code: .confirmRequired,
        message:
          "Dumping \(size) bytes needs confirmation (more than \(Self.confirmAbove >> 20) MB).",
        hint: "Call vm_memory_dump again with confirm: true, or dump a smaller range.",
        data: ["bytes": .number(Double(size))])
    }
    let name = Self.fileName(address: address, size: size, at: Date())
    let policy = PathPolicy.load(home: context.home)
    let target = try VMFileHandler.localPath(
      try arguments.string("local"), policy: policy, access: .write
    ).map { local throws(VMLabError) in
      try LocalDestination.open(local, defaultName: name, policy: policy)
    }
    defer { target?.close() }
    let vm = try await context.manager.attach(try arguments.string("vm") ?? "")
    let dumper = try vm.channel(.memoryDump)
    let directory = context.store.directory(of: vm.id).appending(path: "dumps")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw ToolRendering.internalError(error, doing: "creating \(directory.path)")
    }
    let request = MemoryDumpRequest(
      address: address, size: size, path: directory.appending(path: name))
    guard let target else { return Self.render(try await dumper.dump(request)) }
    return try await Self.dump(request, to: target, staging: directory, with: dumper)
  }

  /// Dumps `request` to `<final>.part` in a fresh folder under `staging` (the VM's `dumps/`,
  /// which no guest reaches) and renames it into `target`'s checked directory.
  static func dump(
    _ request: MemoryDumpRequest, to target: LocalDestination, staging: URL,
    with dumper: any MemoryDumper
  ) async throws(VMLabError) -> ToolResult {
    let folder = staging.appending(path: ".staging-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    } catch {
      throw ToolRendering.internalError(error, doing: "creating \(folder.path)")
    }
    defer { try? FileManager.default.removeItem(at: folder) }
    var staged = request
    staged.path = folder.appending(path: target.name + ".part")
    var result = try await dumper.dump(staged)
    try target.move(staged.path)
    result.path = target.url
    return render(result)
  }

  static func render(_ result: MemoryDumpResult) -> ToolResult {
    ToolResult([
      "path": .string(result.path.path), "bytes": .number(Double(result.bytes)),
      "format": .string(result.format.rawValue),
    ])
  }

  /// A `0x` hex address; nil when absent.
  static func address(_ text: String?) throws(VMLabError) -> UInt64? {
    guard let text else { return nil }
    let lower = text.lowercased()
    guard lower.hasPrefix("0x"), let value = UInt64(lower.dropFirst(2), radix: 16) else {
      throw VMLabError.invalidRequest(
        field: "address", reason: "address must be 0x hex, not \(text)",
        hint: "Pass the guest physical address like 0x40000000.")
    }
    return value
  }

  static func fileName(address: UInt64?, size: UInt64?, at date: Date) -> String {
    var style = Date.ISO8601FormatStyle(timeZone: .gmt)
    style = style.year().month().day().time(includingFractionalSeconds: true)
    let stamp = date.formatted(style).replacingOccurrences(of: ":", with: "")
    guard let address, let size else { return "\(stamp).elf" }
    return "\(stamp)-0x\(String(address, radix: 16))-\(size).raw"
  }
}
