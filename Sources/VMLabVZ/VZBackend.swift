import Foundation
import VMLabCore

/// The `vz-linux` backend: each guest is a detached `vmlab-vz` runner driven over its control
/// socket. R-600 boots an EFI Linux disk with the minimal `VZRunnerConfig.linuxEFI`; R-601 makes
/// the full configuration (seed, stable MAC, leased IP), R-602 the serial channel and R-605 the
/// checkpoints, so `attach` offers none of those channels yet.
public struct VZBackend: Backend {
  public let profile: Profile = .vzLinux
  public let store: Store
  public let launcher: VZRunnerLauncher
  /// How long `stop` waits for the guest to power off.
  public var stopTimeout: Duration

  public init(
    store: Store, launcher: VZRunnerLauncher = VZRunnerLauncher(),
    stopTimeout: Duration = .seconds(120)
  ) {
    self.store = store
    self.launcher = launcher
    self.stopTimeout = stopTimeout
  }

  func paths(_ record: VMRecord) -> VZRunnerPaths {
    VZRunnerPaths(vmDirectory: store.directory(of: record.id))
  }

  /// Clones the pulled image's raw disk to `<vm>/disk.raw` (an APFS clone, so instant).
  public func create(_ record: VMRecord, plan: Plan) async throws(VMLabError) {
    guard let name = record.image else { return }
    let images = ImageStore(home: store.home)
    guard let pulled = images.pulled(name), let raw = pulled.files["raw"] else {
      throw VMLabError(
        code: .imageNotFound, message: "Image \(name) has no pulled raw disk",
        hint: "Run vmlab images pull \(name).", data: ["image": .string(name)])
    }
    let disk = store.directory(of: record.id).appending(path: "disk.raw")
    guard !FileManager.default.fileExists(atPath: disk.path) else { return }
    do {
      try FileManager.default.copyItem(
        at: images.imageDirectory(name).appending(path: raw), to: disk)
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot clone \(name) to \(disk.path): \(error)",
        hint: "Check free disk space and permissions under VMLAB_HOME.")
    }
  }

  public func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    let dir = store.directory(of: record.id)
    let handle = try await launcher.launch(
      vmDirectory: dir, config: .linuxEFI(record: record, vmDirectory: dir))
    return handle.runtime
  }

  public func stop(_ record: VMRecord) async throws(VMLabError) {
    let (client, pid) = target(record)
    // A paused guest cannot hear the power button; Lifecycle allows stop from paused.
    if try await client.status().state == .paused { try await client.resume() }
    try await client.stop()
    try await waitForExit(pid, within: stopTimeout, record: record, action: "stop")
  }

  public func kill(_ record: VMRecord) async throws(VMLabError) {
    let (client, pid) = target(record)
    do {
      try await client.kill()
    } catch  where error.code == .guestUnreachable || error.code == .timeout {
      if pid > 0 { Foundation.kill(pid, SIGKILL) }
    }
    try await waitForExit(pid, within: .seconds(15), record: record, action: "kill")
  }

  public func pause(_ record: VMRecord) async throws(VMLabError) {
    try await target(record).client.pause()
  }

  public func resume(_ record: VMRecord) async throws(VMLabError) {
    try await target(record).client.resume()
  }

  /// Ends a runner that is somehow still there; the manager removes the directory.
  public func destroy(_ record: VMRecord) async throws(VMLabError) {
    let (client, pid) = target(record)
    if (try? await client.exit()) == nil, pid > 0, LivenessProbe.processExists(pid) {
      Foundation.kill(pid, SIGKILL)
    }
  }

  public func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM {
    let handle = try await VMLabVZ.attach(socketPath: target(record).client.socketPath)
    return VZRunningVM(id: record.id, profile: profile, features: record.features, handle: handle)
  }

  /// The runner's client and pid, from the record's runtime or the VM directory.
  func target(_ record: VMRecord) -> (client: VZControlClient, pid: Int32) {
    let paths = paths(record)
    let socket = record.runtime?.controlSocket ?? paths.controlSocket.path
    return (VZControlClient(socketPath: socket), record.runtime?.pid ?? paths.recordedPID() ?? 0)
  }

  func waitForExit(_ pid: Int32, within limit: Duration, record: VMRecord, action: String)
    async throws(VMLabError)
  {
    guard pid > 0 else { return }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while LivenessProbe.processExists(pid) {
      if clock.now >= deadline {
        throw VMLabError(
          code: .timeout,
          message: "VM \(record.id) did not \(action) within \(limit)",
          hint: action == "stop"
            ? "The guest ignored the shutdown request; use kill." : "Check <vm>/vz.log.",
          data: ["vm": .string(record.id), "pid": .number(Double(pid))])
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
}

/// A running VZ guest. Serial (R-602), display (R-503) and checkpoints (R-605) are not wired yet.
public struct VZRunningVM: RunningVM {
  public let id: String
  public let profile: Profile
  public let features: [Feature]
  public let handle: VZRunnerHandle

  public var serial: SerialChannel? { nil }
  public var display: DisplayEndpoint? { nil }
  public var gdb: GDBEndpoint? { nil }
  public var introspection: (any Introspection)? { nil }
  public var exec: any ExecChannel { NotYet(vm: id, channel: "exec", item: "R-400") }
  public var checkpoints: any CheckpointProvider {
    NotYet(vm: id, channel: "checkpoints", item: "R-605")
  }

  struct NotYet: ExecChannel, CheckpointProvider {
    let vm: String
    let channel: String
    let item: String

    var error: VMLabError {
      VMLabError(
        code: .guestUnreachable,
        message: "VM \(vm)'s \(channel) channel is not available on vz-linux in this build",
        hint: "This build does not implement it yet (\(item)).",
        data: ["vm": .string(vm), "channel": .string(channel)])
    }

    func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult { throw error }
    func create(id: String, mode: CheckpointMode) async throws(VMLabError) { throw error }
    func restore(id: String, mode: CheckpointMode) async throws(VMLabError) { throw error }
    func delete(id: String) async throws(VMLabError) { throw error }
  }
}
