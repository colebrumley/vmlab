import Darwin
import Foundation
import VMLabCore

/// Clones of QEMU guests (R-803). The clone's `disk.qcow2` is a fresh overlay
/// (`qemu-img create -b`) over a frozen layer kept in the source's directory,
/// `backing/<key>.qcow2`, which nothing writes again:
///
/// - the current disk of a stopped source: an APFS clone of its `disk.qcow2` (key `disk-<clone>`);
/// - a checkpoint of a stopped source: an APFS clone with the checkpoint applied
///   (`qemu-img snapshot -a`), key the checkpoint id, shared by every clone of that checkpoint;
/// - a checkpoint of a running source: `qemu-img convert -U -l snapshot.name=<id>` of that
///   snapshot (immutable while QEMU runs) into a delta over the source's own backing file.
///
/// The source's EFI variables are copied too, so the clone keeps its boot entries. The recorded
/// chain comes from `qemu-img info --backing-chain`.
extension QEMUBackend {
  public var supportsClone: Bool { true }

  public static let backingDirectory = "backing"

  public func clone(
    _ source: VMRecord, checkpoint: CheckpointNode?, into target: VMRecord
  ) async throws(VMLabError) -> [URL] {
    let img = try installation().qemuImg
    let from = layout(of: source.id)
    let to = layout(of: target.id)
    guard FileManager.default.fileExists(atPath: from.disk.path) else {
      throw VMLabError(
        code: .wrongState, message: "VM \(source.id) has no disk.qcow2 to clone",
        hint: "Start the VM once (vm_lifecycle start) so its disk exists, or create a new VM.",
        data: ["vm": .string(source.id), "state": .string(source.state.rawValue)])
    }
    let live = QEMUMachine.readPID(from).map(QEMUMachine.isAlive) ?? false
    let directory = from.directory.appending(path: Self.backingDirectory)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw QEMUMachine.ioError("create \(directory.path)", error)
    }

    let frozen: URL
    if let checkpoint {
      frozen = directory.appending(path: "\(checkpoint.id).qcow2")
      if !FileManager.default.fileExists(atPath: frozen.path) {
        let tags = try await checkpointProvider(source).tags()
        guard tags.contains(checkpoint.id) else { throw QEMUCheckpoints.missing(checkpoint.id) }
        let temp = directory.appending(path: ".\(checkpoint.id).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        if live {
          let base = try Self.backingFile(of: from.disk, qemuImg: img)
          var arguments = [
            "convert", "-U", "-q", "-O", "qcow2", "-l", "snapshot.name=\(checkpoint.id)",
          ]
          if let base { arguments += ["-F", "qcow2", "-B", base.path] }
          try QEMUMachine.run(
            img, arguments + [from.disk.path, temp.path], step: "qemu-img convert")
        } else {
          try Self.cloneFile(from.disk, to: temp)
          try QEMUMachine.run(
            img, ["snapshot", "-a", checkpoint.id, temp.path], step: "qemu-img snapshot -a")
        }
        try Self.publish(temp, as: frozen)
      }
    } else {
      guard !live else {
        throw VMLabError(
          code: .wrongState, message: "VM \(source.id) is running; its current disk changes",
          hint: "Stop it first (vm_lifecycle stop), or clone from a checkpoint.",
          data: ["vm": .string(source.id), "state": .string(VMState.running.rawValue)])
      }
      frozen = directory.appending(path: "disk-\(target.id).qcow2")
      try Self.cloneFile(from.disk, to: frozen)
    }

    // APFS clones keep the source's dates; `vmlab gc` spares backing files younger than its grace.
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: frozen.path)
    do {
      try FileManager.default.createDirectory(at: to.directory, withIntermediateDirectories: true)
    } catch {
      throw QEMUMachine.ioError("create \(to.directory.path)", error)
    }
    try QEMUMachine.run(
      img, ["create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", frozen.path, to.disk.path],
      step: "qemu-img create")
    if FileManager.default.fileExists(atPath: from.efiVars.path) {
      try Self.cloneFile(from.efiVars, to: to.efiVars)
    }
    return try Self.backingChain(of: to.disk, qemuImg: img)
  }

  /// The files `disk` reads through, nearest first (not `disk` itself).
  static func backingChain(of disk: URL, qemuImg: URL) throws(VMLabError) -> [URL] {
    let output = try info(disk, qemuImg: qemuImg, ["--backing-chain"])
    guard let data = output.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      let images = value.arrayValue
    else { return [] }
    return images.dropFirst().compactMap { $0["filename"]?.stringValue }.map {
      URL(filePath: $0)
    }
  }

  /// The immediate backing file of `disk`, nil when it has none.
  static func backingFile(of disk: URL, qemuImg: URL) throws(VMLabError) -> URL? {
    let output = try info(disk, qemuImg: qemuImg, [])
    guard let data = output.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    let name = value["full-backing-filename"]?.stringValue ?? value["backing-filename"]?.stringValue
    return name.map { URL(filePath: $0) }
  }

  /// `qemu-img info -U --output=json` (shared: the disk may be open in a running QEMU).
  static func info(_ disk: URL, qemuImg: URL, _ extra: [String]) throws(VMLabError) -> String {
    guard FileManager.default.isExecutableFile(atPath: qemuImg.path),
      let result = ProcessRunner().run(
        qemuImg.path, ["info", "-U", "--output=json"] + extra + [disk.path])
    else { throw QEMUInstallation.missingTool("qemu-img", path: qemuImg.path) }
    guard result.status == 0 else {
      throw VMLabError(
        code: .engineError, message: "qemu-img info failed with status \(result.status).",
        hint: "See data.raw for qemu-img's message.",
        data: ["engine": .string("qemu"), "raw": .string(result.output)])
    }
    return result.output
  }

  /// An APFS clone of `source` at `destination` (`clonefile(2)`), a copy where the volume
  /// cannot clone.
  static func cloneFile(_ source: URL, to destination: URL) throws(VMLabError) {
    if clonefile(source.path, destination.path, 0) == 0 { return }
    do {
      try FileManager.default.copyItem(at: source, to: destination)
    } catch {
      throw QEMUMachine.ioError("copy \(source.path) to \(destination.path)", error)
    }
  }

  /// Renames a finished temporary file into place; when another clone got there first, keeps
  /// theirs.
  static func publish(_ temp: URL, as final: URL) throws(VMLabError) {
    if renamex_np(temp.path, final.path, UInt32(RENAME_EXCL)) == 0 || errno == EEXIST { return }
    throw QEMUMachine.ioError(
      "rename \(temp.path)", POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
  }
}
