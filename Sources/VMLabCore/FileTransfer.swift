import Foundation

/// What `vm_file` copied (R-404): the bytes of every regular file, and where they landed.
public struct FileTransferResult: Sendable, Hashable {
  public var bytes: Int64
  public var path: String

  public init(bytes: Int64, path: String) {
    self.bytes = bytes
    self.path = path
  }
}

/// Copies files between the host and a guest with the system `scp` in SFTP mode (`-s`, so the
/// guest path is taken literally and never seen by a remote shell), recursively, with the VM's
/// key and known-hosts file (`SSHTarget.options`).
public struct SSHFileTransfer: Sendable {
  public static let scp = "/usr/bin/scp"
  public static let defaultTimeout: Duration = .seconds(600)

  public var target: SSHTarget
  public var scp: String

  public init(target: SSHTarget, scp: String = SSHFileTransfer.scp) {
    self.target = target
    self.scp = scp
  }

  /// `<vm>/pulled/`, where a pull with no local path goes.
  public var pulledDirectory: URL { target.vmDirectory.appending(path: "pulled") }

  /// `user@host:path`, with an IPv6 host in brackets.
  public func remoteSpec(_ path: String) -> String {
    let host =
      target.endpoint.host.contains(":") ? "[\(target.endpoint.host)]" : target.endpoint.host
    return "\(target.user)@\(host):\(path)"
  }

  /// The `scp` argument vector copying `source` to `destination` (one of them a `remoteSpec`).
  public func arguments(source: String, destination: String) -> [String] {
    ["-s", "-r", "-q", "-P", String(target.endpoint.port)] + target.options() + [
      source, destination,
    ]
  }

  /// Copies the host file or directory `local` to `remote` in the guest.
  public func push(local: URL, remote: String, timeout: Duration = defaultTimeout)
    async throws(VMLabError) -> FileTransferResult
  {
    try Self.checkRemote(remote)
    guard FileManager.default.fileExists(atPath: local.path) else {
      throw VMLabError.invalidRequest(
        field: "local", reason: "\(local.path) does not exist",
        hint: "Give the absolute path of a host file or directory to push.")
    }
    try await copy(source: local.path, destination: remoteSpec(remote), timeout: timeout)
    return FileTransferResult(bytes: Self.bytes(at: local), path: remote)
  }

  /// Copies `remote` from the guest to `local`, or into `<vm>/pulled/` when `local` is nil. A
  /// `local` that is an existing directory receives the copy inside it, as `scp` does.
  public func pull(remote: String, local: URL?, timeout: Duration = defaultTimeout)
    async throws(VMLabError) -> FileTransferResult
  {
    try Self.checkRemote(remote)
    let name = Self.baseName(of: remote)
    let destination: URL
    let files = FileManager.default
    if let local {
      var isDirectory: ObjCBool = false
      if files.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue {
        destination = local.appending(path: name)
      } else {
        destination = local
      }
    } else {
      do {
        try files.createDirectory(at: pulledDirectory, withIntermediateDirectories: true)
      } catch {
        throw VMLabError(
          code: .internal, message: "Cannot create \(pulledDirectory.path)",
          hint: "Check that the VM directory is writable.", data: ["error": .string("\(error)")])
      }
      destination = pulledDirectory.appending(path: name)
      // A fresh copy, so a directory pulled twice does not land inside the first copy.
      try? files.removeItem(at: destination)
    }
    try await copy(source: remoteSpec(remote), destination: destination.path, timeout: timeout)
    return FileTransferResult(bytes: Self.bytes(at: destination), path: destination.path)
  }

  private func copy(source: String, destination: String, timeout: Duration)
    async throws(VMLabError)
  {
    let errors = target.vmDirectory.appending(path: "exec/scp-\(UUID().uuidString).stderr")
    try? FileManager.default.createDirectory(
      at: errors.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: errors.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: errors) }
    let handle = try? FileHandle(forWritingTo: errors)
    let outcome = try await HostProcess.run(
      scp, arguments(source: source, destination: destination),
      stderr: handle ?? .nullDevice, timeout: timeout)
    try? handle?.close()
    let stderr = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
    if outcome.timedOut {
      throw VMLabError(
        code: .timeout,
        message: "The copy did not finish within \(Int(timeout / .seconds(1))) s and was stopped",
        hint: "Copy less at once, or use a shared directory (share) for large trees.",
        data: ["vm": .string(target.vm), "timeoutSeconds": .number(Double(timeout / .seconds(1)))])
    }
    guard outcome.status != 0 else { return }
    if SSHExecChannel.isSSHFailure(stderr) || SSHExecChannel.isConnectFailure(stderr) {
      throw SSHExecChannel.unreachable(target, stderr)
    }
    let last =
      stderr.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
      ?? "scp exited with status \(outcome.status)"
    throw VMLabError.invalidRequest(
      field: "remote", reason: last,
      hint: "Check that the guest path exists and the login user may read or write it.")
  }

  static func checkRemote(_ remote: String) throws(VMLabError) {
    guard !remote.isEmpty, !remote.contains("\n"), !remote.contains("\0") else {
      throw VMLabError.invalidRequest(
        field: "remote", reason: "the guest path must be a non-empty single line",
        hint: "Give a guest path such as /home/debian/file.txt.")
    }
  }

  /// The last component of a guest path, ignoring trailing slashes.
  static func baseName(of remote: String) -> String {
    let trimmed = remote.split(separator: "/").last.map(String.init) ?? ""
    return trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed == "~"
      ? "pulled" : trimmed
  }

  /// The size of a file, or of every regular file under a directory.
  public static func bytes(at url: URL) -> Int64 {
    let files = FileManager.default
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    guard isDirectory.boolValue else {
      let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
      return size?.int64Value ?? 0
    }
    var total: Int64 = 0
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    if let walker = files.enumerator(at: url, includingPropertiesForKeys: keys) {
      for case let file as URL in walker {
        guard let values = try? file.resourceValues(forKeys: Set(keys)),
          values.isRegularFile == true
        else { continue }
        total += Int64(values.fileSize ?? 0)
      }
    }
    return total
  }
}
