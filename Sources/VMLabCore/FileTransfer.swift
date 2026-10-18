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
    try await copy(source: local.path, destination: remoteSpec(remote), timeout: timeout) {
      ["bytesTotal": .number(Double(Self.bytes(at: local))), "path": .string(remote)]
    }
    return FileTransferResult(bytes: Self.bytes(at: local), path: remote)
  }

  /// Copies `remote` from the guest to `local`, or into `<vm>/pulled/` when `local` is nil. A
  /// `local` that is an existing directory receives the copy inside it, as `scp` does.
  ///
  /// A `local` copy is a host write the model names: the final destination passes `policy` as a
  /// write path (when given), and `scp` writes into a staging folder in `<vm>/pulled/`, which no
  /// guest can reach, whose result is then renamed into a destination directory opened with
  /// `O_NOFOLLOW_ANY`, so a symlink put in the way since the check (by a guest writing a shared
  /// folder, say) is neither followed nor written through: one at the final name is replaced.
  public func pull(
    remote: String, local: URL?, policy: PathPolicy? = nil, timeout: Duration = defaultTimeout
  ) async throws(VMLabError) -> FileTransferResult {
    try Self.checkRemote(remote)
    let name = Self.baseName(of: remote)
    let files = FileManager.default
    guard let local else {
      try Self.createDirectory(pulledDirectory)
      let destination = pulledDirectory.appending(path: name)
      // A fresh copy, so a directory pulled twice does not land inside the first copy.
      try? files.removeItem(at: destination)
      try await copy(source: remoteSpec(remote), destination: destination.path, timeout: timeout) {
        // Partial data (R-1101): what had landed when the copy was stopped; it is left in place.
        [
          "bytesCopied": .number(Double(Self.bytes(at: destination))),
          "path": .string(destination.path),
        ]
      }
      return FileTransferResult(bytes: Self.bytes(at: destination), path: destination.path)
    }
    var isDirectory: ObjCBool = false
    let into =
      files.fileExists(atPath: local.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
    let requested = into ? local.appending(path: name) : local
    let destination =
      try policy?.check(requested.path, field: "local", access: .write)
      ?? URL(filePath: PathPolicy.canonical(requested.path))
    let parentPath = destination.deletingLastPathComponent().path
    let finalName = destination.lastPathComponent
    let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard parent >= 0 else {
      throw VMLabError.invalidRequest(
        field: "local",
        reason: "\(parentPath) is not an existing directory reached without a symlink",
        hint: "Pull into an existing directory, giving its real path.")
    }
    defer { close(parent) }
    var info = stat()
    if fstatat(parent, finalName, &info, AT_SYMLINK_NOFOLLOW) == 0,
      info.st_mode & S_IFMT == S_IFDIR
    {
      throw VMLabError.invalidRequest(
        field: "local", reason: "\(destination.path) already exists as a directory",
        hint: "Pull to a new path, or into the directory that should receive the copy.")
    }
    let staging = pulledDirectory.appending(path: ".staging-\(UUID().uuidString)")
    try Self.createDirectory(staging)
    let staged = staging.appending(path: finalName)
    var keepStaging = false
    defer { if !keepStaging { try? files.removeItem(at: staging) } }
    do {
      try await copy(source: remoteSpec(remote), destination: staged.path, timeout: timeout) {
        [
          "bytesCopied": .number(Double(Self.bytes(at: staged))), "path": .string(staged.path),
        ]
      }
    } catch {
      // A timeout's partial data stays in the staging folder its refusal names.
      keepStaging = error.code == .timeout
      throw error
    }
    try Self.move(staged, into: parent, name: finalName, shown: destination.path)
    return FileTransferResult(bytes: Self.bytes(at: destination), path: destination.path)
  }

  static func createDirectory(_ url: URL) throws(VMLabError) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot create \(url.path)",
        hint: "Check that the VM directory is writable.", data: ["error": .string("\(error)")])
    }
  }

  /// Renames `source` to `name` in the directory `parent`, replacing a file or symlink there and
  /// never following one; across volumes, copies it in with `openat(O_NOFOLLOW)`.
  static func move(_ source: URL, into parent: Int32, name: String, shown: String)
    throws(VMLabError)
  {
    if renameat(AT_FDCWD, source.path, parent, name) == 0 { return }
    var code = errno
    if code == EXDEV {
      code = copyTree(source.path, into: parent, name: name)
      if code == 0 { return }
    }
    throw VMLabError.invalidRequest(
      field: "local", reason: "cannot write \(shown): \(String(cString: strerror(code)))",
      hint: "Pull to a new path in a directory you can write.")
  }

  /// Copies the file or directory at `source` to `name` in `parent` without following a symlink
  /// on the destination side; 0, or the errno that stopped it.
  static func copyTree(_ source: String, into parent: Int32, name: String) -> Int32 {
    var info = stat()
    guard lstat(source, &info) == 0 else { return errno }
    switch info.st_mode & S_IFMT {
    case S_IFDIR:
      guard mkdirat(parent, name, 0o755) == 0 else { return errno }
      let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard child >= 0 else { return errno }
      defer { close(child) }
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: source)) ?? []
      for entry in entries {
        let code = copyTree(source + "/" + entry, into: child, name: entry)
        if code != 0 { return code }
      }
      return 0
    case S_IFREG:
      var existing = stat()
      if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
        guard unlinkat(parent, name, 0) == 0 else { return errno }
      }
      let output = openat(
        parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
      guard output >= 0 else { return errno }
      defer { close(output) }
      let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard input >= 0 else { return errno }
      defer { close(input) }
      return fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 ? 0 : errno
    default:
      return 0  // scp makes no links or devices; nothing else is copied.
    }
  }

  /// Runs scp; on a timeout the refusal's `data` adds what `partial` reports.
  private func copy(
    source: String, destination: String, timeout: Duration,
    partial: () -> [String: JSONValue] = { [:] }
  ) async throws(VMLabError) {
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
        data: partial().merging(
          ["vm": .string(target.vm), "timeoutSeconds": .number(Double(timeout / .seconds(1)))],
          uniquingKeysWith: { $1 }))
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
