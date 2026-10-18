import Foundation

/// A background command (R-402) as `<vm>/exec/<job>.json` records it. The output streams into
/// `<vm>/exec/<job>.log`; `readOffset` is how much of it `vm_job read` has returned.
public struct ExecJob: Codable, Sendable, Hashable {
  public var id: String
  public var vm: String
  public var command: String
  /// The guest user it runs as; nil for the login user.
  public var user: String?
  public var startedAt: Date
  public var readOffset: UInt64
  public var exitCode: Int32?
  public var finishedAt: Date?
  /// The guest lost the job's files (a reboot clears `/tmp`): it ended with no known status.
  public var lost: Bool

  public var finished: Bool { exitCode != nil || lost }
}

/// What `read`, `wait` and `kill` return: output not returned before, and whether the job ended.
public struct ExecJobRead: Sendable, Hashable {
  public var output: String
  public var finished: Bool
  public var exitCode: Int32?
  /// Unread output remains (a read returns at most `ExecJobs.readLimit` bytes).
  public var more: Bool
  public var logPath: String
  public var warnings: [String]
}

/// The background jobs of every VM this process serves. A job runs in the guest under `nohup`,
/// in a process group of its own, with its output in `/tmp/vmlab-exec-<uid>/<job>/out` and its
/// status in `rc`. A reader (`ssh ... tail -f`) appends the output to the local log while it runs
/// and ends once `rc` exists; a final `tail -c +<n>` fetches anything the reader had not yet
/// passed on. A job outlives the server: a read in a fresh process starts a new reader from the
/// local log's size.
public actor ExecJobs {
  public static let shared = ExecJobs()
  /// The most a read returns at once.
  public static let readLimit = 64 * 1024

  private var readers: [String: Task<Void, Never>] = [:]

  public init() {}

  // MARK: Model-facing operations

  /// Starts `request` in the background and returns its job at once.
  public func start(_ request: ExecRequest, on channel: SSHExecChannel) async throws(VMLabError)
    -> ExecJob
  {
    let job = ExecJob(
      id: SSHExecChannel.newJobID(), vm: channel.target.vm, command: request.command,
      user: request.user, startedAt: Date(), readOffset: 0, exitCode: nil, finishedAt: nil,
      lost: false)
    let paths = Paths(channel: channel, job: job.id)
    try paths.prepare()
    try save(job, paths)
    let remote = RemoteShell.background(request, job: job.id, loginUser: channel.target.user)
    let result = try await Self.ssh(channel, remote: remote, timeout: .seconds(30))
    guard result.status == 0, result.stdout.contains("vmlab-started") else {
      try? FileManager.default.removeItem(at: paths.record)
      try? FileManager.default.removeItem(at: paths.log)
      if result.status == 255, SSHExecChannel.isSSHFailure(result.stderr) {
        throw SSHExecChannel.unreachable(channel.target, result.stderr)
      }
      throw VMLabError(
        code: .guestUnreachable, message: "The guest did not start the background job",
        hint: "See data.error; the guest needs /bin/sh, nohup and /tmp.",
        data: [
          "vm": .string(job.vm), "tried": .array([.string("ssh")]),
          "error": .string(result.stderr), "status": .number(Double(result.status)),
        ])
    }
    ensureReader(job, channel: channel, paths: paths)
    return job
  }

  /// The output written since the last read, and whether the job finished.
  public func read(_ id: String, on channel: SSHExecChannel) throws(VMLabError) -> ExecJobRead {
    let paths = Paths(channel: channel, job: id)
    var job = try load(id, paths)
    if !job.finished { ensureReader(job, channel: channel, paths: paths) }
    let (data, end, more) = Self.newOutput(of: paths.log, from: job.readOffset, all: job.finished)
    job.readOffset = end
    try save(job, paths)
    var warnings: [String] = []
    if job.lost {
      warnings.append(
        "the guest no longer has job \(id)'s files (a reboot clears /tmp); its status is unknown")
    }
    return ExecJobRead(
      output: String(decoding: data, as: UTF8.self), finished: job.finished,
      exitCode: job.exitCode, more: more, logPath: paths.log.path, warnings: warnings)
  }

  /// Blocks until the job finishes or `timeout` passes, then reads.
  public func wait(_ id: String, on channel: SSHExecChannel, timeout: Duration)
    async throws(VMLabError) -> ExecJobRead
  {
    let paths = Paths(channel: channel, job: id)
    let deadline = ContinuousClock.now + timeout
    var job = try load(id, paths)
    while !job.finished, ContinuousClock.now < deadline, !Task.isCancelled {
      ensureReader(job, channel: channel, paths: paths)
      try? await Task.sleep(for: .milliseconds(200))
      job = try load(id, paths)
    }
    return try read(id, on: channel)
  }

  /// Ends the job's process group (TERM, then KILL), waits briefly for its status, and reads.
  public func kill(_ id: String, on channel: SSHExecChannel) async throws(VMLabError)
    -> ExecJobRead
  {
    let paths = Paths(channel: channel, job: id)
    let job = try load(id, paths)
    if !job.finished {
      let remote = RemoteShell.kill(job: id, user: job.user, loginUser: channel.target.user)
      let result = try await Self.ssh(channel, remote: remote, timeout: .seconds(15))
      if result.status == 255, SSHExecChannel.isSSHFailure(result.stderr) {
        throw SSHExecChannel.unreachable(channel.target, result.stderr)
      }
      return try await wait(id, on: channel, timeout: .seconds(10))
    }
    return try read(id, on: channel)
  }

  // MARK: Reader

  /// Starts the reader of `job` unless one runs in this process.
  private func ensureReader(_ job: ExecJob, channel: SSHExecChannel, paths: Paths) {
    let key = paths.log.path
    guard readers[key] == nil else { return }
    readers[key] = Task.detached { [self] in
      await Self.follow(job, channel: channel, paths: paths)
      await self.readerEnded(key)
    }
  }

  private func readerEnded(_ key: String) { readers[key] = nil }

  /// Ends this process's readers (their ssh connections); the jobs keep running in the guest and
  /// the next read starts new readers. What a server does on the way out.
  public func stopReaders() async {
    let running = Array(readers.values)
    for reader in running { reader.cancel() }
    for reader in running { await reader.value }
  }

  /// One reader run: `tail -f` from the log's size until `rc` exists, then the catch-up and the
  /// status. A reader that loses the connection just ends; the next read starts another.
  static func follow(_ job: ExecJob, channel: SSHExecChannel, paths: Paths) async {
    let offset = paths.logSize()
    // O_APPEND: a reader of an earlier server that is still winding down cannot overwrite.
    let fd = open(paths.log.path, O_WRONLY | O_APPEND | O_CLOEXEC)
    guard fd >= 0 else { return }
    let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let errors = paths.scratch("reader")
    defer { try? FileManager.default.removeItem(at: errors) }
    FileManager.default.createFile(atPath: errors.path, contents: nil)
    guard let errorHandle = try? FileHandle(forWritingTo: errors) else { return }
    let remote = RemoteShell.follow(
      job: job.id, offset: offset, user: job.user, loginUser: channel.target.user)
    _ = try? await HostProcess.run(
      channel.ssh, channel.target.arguments(remote: remote), stdout: log, stderr: errorHandle)
    try? errorHandle.close()
    let text = String(decoding: (try? Data(contentsOf: errors)) ?? Data(), as: UTF8.self)
    var finished = job
    if let code = Self.exitCode(in: text) {
      // Everything the reader did not pass on yet, then the job's files go.
      let remote = RemoteShell.collect(
        job: job.id, offset: paths.logSize(), user: job.user, loginUser: channel.target.user)
      _ = try? await HostProcess.run(
        channel.ssh, channel.target.arguments(remote: remote), stdout: log,
        timeout: .seconds(60))
      finished.exitCode = code
    } else if text.contains(RemoteShell.missingMarker) {
      finished.lost = true
    } else {
      try? log.close()
      return
    }
    try? log.close()
    finished.finishedAt = Date()
    guard var current = try? Self.loadRecord(paths) else { return }
    current.exitCode = finished.exitCode
    current.lost = finished.lost
    current.finishedAt = finished.finishedAt
    try? Self.saveRecord(current, paths)
  }

  static func exitCode(in readerErrors: String) -> Int32? {
    for line in readerErrors.split(separator: "\n").reversed() {
      if line.hasPrefix(RemoteShell.exitMarker),
        let code = Int32(line.dropFirst(RemoteShell.exitMarker.count))
      {
        return code
      }
    }
    return nil
  }

  // MARK: Files

  struct Paths: Sendable {
    let directory: URL
    let job: String

    init(channel: SSHExecChannel, job: String) {
      directory = channel.execDirectory
      self.job = job
    }

    var record: URL { directory.appending(path: "\(job).json") }
    var log: URL { directory.appending(path: "\(job).log") }
    func scratch(_ name: String) -> URL { directory.appending(path: "\(job).\(name)") }

    func prepare() throws(VMLabError) {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        throw VMLabError(
          code: .internal, message: "Cannot create \(directory.path): \(error)",
          hint: "Check that the VM directory is writable.", data: ["id": .string(job)])
      }
      FileManager.default.createFile(atPath: log.path, contents: nil)
    }

    func logSize() -> UInt64 {
      ((try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? NSNumber)?
        .uint64Value ?? 0
    }
  }

  /// A job id is `j-` and twelve hex digits; anything else never names a file.
  public static func isValidJobID(_ id: String) -> Bool {
    id.count == 14 && id.hasPrefix("j-")
      && id.dropFirst(2).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  private func load(_ id: String, _ paths: Paths) throws(VMLabError) -> ExecJob {
    guard Self.isValidJobID(id), let job = try? Self.loadRecord(paths) else {
      throw VMLabError.invalidRequest(
        field: "job",
        reason: "\(paths.directory.deletingLastPathComponent().lastPathComponent) "
          + "has no background job \(id)",
        hint: "Use the job id vm_exec returned with background: true.")
    }
    return job
  }

  private func save(_ job: ExecJob, _ paths: Paths) throws(VMLabError) {
    do { try Self.saveRecord(job, paths) } catch {
      throw VMLabError(
        code: .internal, message: "Cannot write \(paths.record.path): \(error)",
        hint: "Check that the VM directory is writable.", data: ["id": .string(job.id)])
    }
  }

  static func loadRecord(_ paths: Paths) throws -> ExecJob {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ExecJob.self, from: Data(contentsOf: paths.record))
  }

  static func saveRecord(_ job: ExecJob, _ paths: Paths) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(job).write(to: paths.record, options: .atomic)
  }

  /// The log's bytes from `offset`, at most `readLimit`, ending on a UTF-8 boundary unless `all`
  /// (the job is over and nothing more will come); the new offset; whether more remains.
  static func newOutput(of log: URL, from offset: UInt64, all: Bool) -> (Data, UInt64, Bool) {
    guard let handle = try? FileHandle(forReadingFrom: log) else { return (Data(), offset, false) }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    guard size > offset else { return (Data(), offset, false) }
    try? handle.seek(toOffset: offset)
    var data = (try? handle.read(upToCount: readLimit)) ?? Data()
    let more = offset + UInt64(data.count) < size
    if more || !all { data = Data(data.prefix(completeUTF8Prefix(data))) }
    return (data, offset + UInt64(data.count), offset + UInt64(data.count) < size)
  }

  /// The length of `data` without a trailing incomplete UTF-8 sequence.
  static func completeUTF8Prefix(_ data: Data) -> Int {
    let bytes = Array(data.suffix(4))
    var index = bytes.count - 1
    var continuation = 0
    while index >= 0, bytes[index] & 0xC0 == 0x80 {
      continuation += 1
      index -= 1
    }
    guard index >= 0 else { return data.count }
    let lead = bytes[index]
    let length =
      lead & 0x80 == 0 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
    return continuation + 1 >= length ? data.count : data.count - (continuation + 1)
  }

  /// One short ssh call: its status and both streams.
  static func ssh(_ channel: SSHExecChannel, remote: String, timeout: Duration)
    async throws(VMLabError) -> (status: Int32, stdout: String, stderr: String)
  {
    let job = SSHExecChannel.newJobID()
    let files = try ExecFiles(directory: channel.execDirectory, job: job)
    defer { files.removeScratch() }
    let outcome = try await HostProcess.run(
      channel.ssh, channel.target.arguments(remote: remote), stdout: files.stdout,
      stderr: files.stderr, timeout: timeout)
    files.close()
    let out = String(decoding: (try? Data(contentsOf: files.stdoutURL)) ?? Data(), as: UTF8.self)
    let err = String(decoding: (try? Data(contentsOf: files.stderrURL)) ?? Data(), as: UTF8.self)
    if outcome.timedOut {
      throw VMLabError(
        code: .timeout, message: "The guest did not answer within \(timeout)",
        hint: "Retry; read vm_serial if the guest seems hung.",
        data: [
          "vm": .string(channel.target.vm),
          "timeoutSeconds": .number(Double(timeout.components.seconds)),
        ])
    }
    return (outcome.status, out, err)
  }
}
