import Foundation
import VMLabCore

/// Checkpoints of a QEMU guest as qcow2 internal snapshots of `disk.qcow2`, tagged with the
/// checkpoint id (R-307).
///
/// A stopped guest gets disk checkpoints through `qemu-img snapshot -c/-a/-d`. A running (or
/// paused) guest gets live checkpoints, memory and disk, through the QMP jobs `snapshot-save`,
/// `snapshot-load` and `snapshot-delete`, when `liveAllowed`: always under TCG, and under HVF only
/// when the host fact `qemu_hvf_live_snapshot` is `yes`. Anything else is `wrong_state` with the
/// hint saying what to change; the guest is never stopped or started implicitly.
public struct QEMUCheckpoints: CheckpointProvider {
  public let backend: QEMUBackend
  public let record: VMRecord
  /// Whether a running guest may be checkpointed with its memory.
  public let liveAllowed: Bool
  /// How long one snapshot job may take (saving memory writes the guest's whole RAM).
  public var jobTimeout: Duration = .seconds(600)

  public init(backend: QEMUBackend, record: VMRecord, liveAllowed: Bool) {
    self.backend = backend
    self.record = record
    self.liveAllowed = liveAllowed
  }

  var layout: QEMULayout { backend.layout(of: record.id) }

  /// Whether a QEMU process runs this guest now (running or paused).
  var isLive: Bool {
    guard let pid = QEMUMachine.readPID(layout) else { return false }
    return QEMUMachine.isAlive(pid)
  }

  public func create(id: String, mode: CheckpointMode) async throws(VMLabError) {
    try Self.validate(tag: id)
    if isLive {
      guard mode == .live else { throw diskNeedsStopped("take a disk checkpoint") }
      try checkLiveAllowed()
      let qmp = try await backend.machine(for: record).qmp
      if try await QMPSnapshots.tags(qmp).contains(id) { throw Self.exists(id) }
      try await QMPSnapshots.save(tag: id, qmp: qmp, timeout: jobTimeout)
    } else {
      guard mode == .disk else { throw liveNeedsRunning("take a live checkpoint") }
      let img = try backend.installation().qemuImg
      if try QEMUImageSnapshots.tags(img, disk: layout.disk).contains(id) { throw Self.exists(id) }
      try QEMUMachine.run(
        img, ["snapshot", "-c", id, layout.disk.path], step: "qemu-img snapshot -c")
    }
  }

  public func restore(id: String, mode: CheckpointMode) async throws(VMLabError) {
    try Self.validate(tag: id)
    if isLive {
      guard mode == .live else { throw diskNeedsStopped("restore a disk checkpoint") }
      try checkLiveAllowed()
      let qmp = try await backend.machine(for: record).qmp
      guard try await QMPSnapshots.tags(qmp).contains(id) else { throw Self.missing(id) }
      try await QMPSnapshots.load(tag: id, qmp: qmp, timeout: jobTimeout)
    } else {
      guard mode == .disk else { throw liveNeedsRunning("restore a live checkpoint") }
      let img = try backend.installation().qemuImg
      guard try QEMUImageSnapshots.tags(img, disk: layout.disk).contains(id) else {
        throw Self.missing(id)
      }
      try QEMUMachine.run(
        img, ["snapshot", "-a", id, layout.disk.path], step: "qemu-img snapshot -a")
    }
  }

  public func delete(id: String) async throws(VMLabError) {
    try Self.validate(tag: id)
    if isLive {
      let qmp = try await backend.machine(for: record).qmp
      guard try await QMPSnapshots.tags(qmp).contains(id) else { throw Self.missing(id) }
      try await QMPSnapshots.delete(tag: id, qmp: qmp, timeout: jobTimeout)
    } else {
      let img = try backend.installation().qemuImg
      guard try QEMUImageSnapshots.tags(img, disk: layout.disk).contains(id) else {
        throw Self.missing(id)
      }
      try QEMUMachine.run(
        img, ["snapshot", "-d", id, layout.disk.path], step: "qemu-img snapshot -d")
    }
  }

  /// The snapshot tags on the guest's disk, from QMP when it runs, else from `qemu-img info`.
  public func tags() async throws(VMLabError) -> [String] {
    if isLive { return try await QMPSnapshots.tags(try await backend.machine(for: record).qmp) }
    return try QEMUImageSnapshots.tags(try backend.installation().qemuImg, disk: layout.disk)
  }

  // MARK: Refusals

  private func checkLiveAllowed() throws(VMLabError) {
    guard !liveAllowed else { return }
    throw VMLabError(
      code: .wrongState,
      message:
        "VM \(record.id) is running, and this host cannot checkpoint a running \(record.profile.rawValue) "
        + "guest (\(SlowProbe.qemuHVFLiveSnapshot.rawValue) is not yes)",
      hint: "Stop the VM first (vm_lifecycle stop), then take a disk checkpoint.",
      data: [
        "vm": .string(record.id), "state": .string(VMState.running.rawValue),
        "legalActions": .array([.string(LifecycleAction.stop.rawValue)]),
        "fact": .string(SlowProbe.qemuHVFLiveSnapshot.rawValue),
      ])
  }

  private func diskNeedsStopped(_ what: String) -> VMLabError {
    VMLabError(
      code: .wrongState,
      message: "VM \(record.id) is running; QEMU can \(what) only while the guest is stopped",
      hint: liveAllowed
        ? "Stop the VM first (vm_lifecycle stop), or use a live checkpoint."
        : "Stop the VM first (vm_lifecycle stop).",
      data: [
        "vm": .string(record.id), "state": .string(VMState.running.rawValue),
        "legalActions": .array([.string(LifecycleAction.stop.rawValue)]),
      ])
  }

  private func liveNeedsRunning(_ what: String) -> VMLabError {
    VMLabError(
      code: .wrongState,
      message: "VM \(record.id) is not running; QEMU can \(what) only in a running guest",
      hint: "Start the VM first (vm_lifecycle start), or use a disk checkpoint.",
      data: [
        "vm": .string(record.id), "state": .string(VMState.stopped.rawValue),
        "legalActions": .array([.string(LifecycleAction.start.rawValue)]),
      ])
  }

  static func exists(_ tag: String) -> VMLabError {
    .invalidRequest(
      field: "id", reason: "a checkpoint \(tag) already exists on this disk",
      hint: "Pick another checkpoint id, or delete the old one first.")
  }

  static func missing(_ tag: String) -> VMLabError {
    .invalidRequest(
      field: "id", reason: "no checkpoint \(tag) exists on this disk",
      hint: "List the VM's checkpoints and use one of their ids.")
  }

  /// Snapshot tags are `[A-Za-z0-9._-]`, at most 64 bytes, and not all digits (QEMU would read a
  /// number as a snapshot's numeric id rather than its tag).
  static func validate(tag: String) throws(VMLabError) {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !tag.isEmpty, tag.utf8.count <= 64, tag.allSatisfy(allowed.contains),
      !tag.allSatisfy(\.isNumber)
    else {
      throw VMLabError.invalidRequest(
        field: "id",
        reason: "checkpoint ids are 1 to 64 of A-Z a-z 0-9 . _ - and not all digits",
        hint: "Use an id such as cp-1.")
    }
  }
}

/// Live snapshots over QMP: the `snapshot-*` jobs on the guest's `disk0` node, polled with
/// `query-jobs` until they conclude, then dismissed.
enum QMPSnapshots {
  /// The `-drive id=` of the guest's system disk (QEMUCommandLine).
  static let diskDevice = "disk0"

  /// The format node of `disk0` and the tags of its internal snapshots, from `query-block`.
  static func disk(_ qmp: QMPClient) async throws(VMLabError) -> (node: String, tags: [String]) {
    let reply = try await QEMUBackend.lift { try await qmp.execute("query-block") }
    for device in reply.arrayValue ?? [] where device["device"]?.stringValue == diskDevice {
      guard let inserted = device["inserted"], let node = inserted["node-name"]?.stringValue
      else { break }
      let snapshots = inserted["image"]?["snapshots"]?.arrayValue ?? []
      return (node, snapshots.compactMap { $0["name"]?.stringValue })
    }
    throw VMLabError(
      code: .engineError, message: "QEMU reports no \(diskDevice) block device for this guest.",
      hint: "Checkpoints need the guest's qcow2 system disk; see qemu.log.",
      data: ["engine": .string("qemu"), "raw": .string("\(reply)")])
  }

  static func tags(_ qmp: QMPClient) async throws(VMLabError) -> [String] {
    try await disk(qmp).tags
  }

  static func save(
    tag: String, qmp: QMPClient, timeout: Duration, poll: Duration = .milliseconds(100)
  ) async throws(VMLabError) {
    let node = try await disk(qmp).node
    try await runJob(
      "snapshot-save", id: "vmlab-save-\(tag)",
      arguments: [
        "tag": .string(tag), "vmstate": .string(node), "devices": .array([.string(node)]),
      ], qmp: qmp, timeout: timeout, poll: poll)
  }

  static func load(
    tag: String, qmp: QMPClient, timeout: Duration, poll: Duration = .milliseconds(100)
  ) async throws(VMLabError) {
    let node = try await disk(qmp).node
    try await runJob(
      "snapshot-load", id: "vmlab-load-\(tag)",
      arguments: [
        "tag": .string(tag), "vmstate": .string(node), "devices": .array([.string(node)]),
      ], qmp: qmp, timeout: timeout, poll: poll)
  }

  static func delete(
    tag: String, qmp: QMPClient, timeout: Duration, poll: Duration = .milliseconds(100)
  ) async throws(VMLabError) {
    let node = try await disk(qmp).node
    try await runJob(
      "snapshot-delete", id: "vmlab-delete-\(tag)",
      arguments: ["tag": .string(tag), "devices": .array([.string(node)])],
      qmp: qmp, timeout: timeout, poll: poll)
  }

  /// Starts the job `command` as `id`, waits for it to conclude and dismisses it. A job that ends
  /// with an `error` is `engine_error` carrying QEMU's message.
  static func runJob(
    _ command: String, id: String, arguments: [String: JSONValue], qmp: QMPClient,
    timeout: Duration, poll: Duration
  ) async throws(VMLabError) {
    var args = arguments
    args["job-id"] = .string(id)
    let started = args
    try await QEMUBackend.lift { try await qmp.execute(command, arguments: started) }
    let deadline = ContinuousClock.now + timeout
    while true {
      let jobs = try await QEMUBackend.lift { try await qmp.execute("query-jobs") }
      let job = jobs.arrayValue?.first { $0["id"]?.stringValue == id }
      let status = job?["status"]?.stringValue
      if status == "concluded" || status == nil {
        if status != nil {
          try await QEMUBackend.lift {
            try await qmp.execute("job-dismiss", arguments: ["id": .string(id)])
          }
        }
        if let message = job?["error"]?.stringValue {
          throw VMLabError(
            code: .engineError, message: "QEMU's \(command) failed: \(message)",
            hint: "See data.raw for QEMU's message.",
            data: [
              "engine": .string("qemu"), "raw": .string(message), "command": .string(command),
            ])
        }
        return
      }
      guard ContinuousClock.now < deadline else {
        throw VMLabError(
          code: .timeout, message: "QEMU's \(command) did not finish in time.",
          hint: "The job may still be running; check vm_introspect status, or kill the VM.",
          data: [
            "timeoutSeconds": .number(QMPClient.seconds(timeout)), "command": .string(command),
          ])
      }
      try? await Task.sleep(for: poll)
    }
  }
}

/// Disk snapshots of a stopped guest with `qemu-img`.
enum QEMUImageSnapshots {
  /// The tags of the internal snapshots of `disk` (`qemu-img info --output=json`); none when the
  /// disk does not exist yet.
  static func tags(_ qemuImg: URL, disk: URL) throws(VMLabError) -> [String] {
    guard FileManager.default.fileExists(atPath: disk.path) else { return [] }
    guard FileManager.default.isExecutableFile(atPath: qemuImg.path),
      let result = ProcessRunner().run(qemuImg.path, ["info", "--output=json", disk.path])
    else { throw QEMUInstallation.missingTool("qemu-img", path: qemuImg.path) }
    guard result.status == 0 else {
      throw VMLabError(
        code: .engineError, message: "qemu-img info failed with status \(result.status).",
        hint: "See data.raw; a running QEMU holds the disk's lock.",
        data: ["engine": .string("qemu"), "raw": .string(result.output)])
    }
    return parseTags(result.output)
  }

  /// The `snapshots[].name` of `qemu-img info --output=json` output.
  static func parseTags(_ json: String) -> [String] {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
      return []
    }
    return (value["snapshots"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
  }
}
