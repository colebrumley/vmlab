import Foundation
import Synchronization
import VMLabCore

/// The `vz-linux` backend: each guest is a detached `vmlab-vz` runner driven over its control
/// socket. Create clones the image and writes the VM's SSH key and cloud-init seed; start launches
/// the runner with `VZRunnerConfig.linux` and records the address the guest leased. A guest granted
/// `serial` gets one `SerialChannel` on the runner's `serial.sock` (R-602), kept for the life of
/// this backend so offsets stay stable across calls. Checkpoints are R-605.
public struct VZBackend: Backend {
  public let profile: Profile = .vzLinux
  public let store: Store
  public let launcher: VZRunnerLauncher
  /// How long `stop` waits for the guest to power off.
  public var stopTimeout: Duration
  /// How long `start` waits for the guest's DHCP lease before recording no `runtime.ip`.
  public var leaseTimeout: Duration
  /// The vmnet lease file (`DHCPLeases.defaultPath`).
  public var leasePath: String
  /// Runs `ssh-keygen` and `hdiutil`.
  public var commands: any CommandRunning
  /// The connected serial channel of each guest, shared by every copy of this backend.
  let serialChannels = VZSerialChannels()

  public init(
    store: Store, launcher: VZRunnerLauncher = VZRunnerLauncher(),
    stopTimeout: Duration = .seconds(120), leaseTimeout: Duration = .seconds(60),
    leasePath: String = DHCPLeases.defaultPath, commands: any CommandRunning = ProcessRunner()
  ) {
    self.store = store
    self.launcher = launcher
    self.stopTimeout = stopTimeout
    self.leaseTimeout = leaseTimeout
    self.leasePath = leasePath
    self.commands = commands
  }

  func paths(_ record: VMRecord) -> VZRunnerPaths {
    VZRunnerPaths(vmDirectory: store.directory(of: record.id))
  }

  /// Clones the pulled image's raw disk to `<vm>/disk.raw` (an APFS clone, so instant), generates
  /// `<vm>/id_ed25519` and writes `<vm>/seed.iso` for the image's login user with the console on
  /// `hvc0`.
  public func create(_ record: VMRecord, plan: Plan) async throws(VMLabError) {
    guard let name = record.image else { return }
    let images = ImageStore(home: store.home)
    guard let pulled = images.pulled(name), let raw = pulled.files["raw"] else {
      throw VMLabError(
        code: .imageNotFound, message: "Image \(name) has no pulled raw disk",
        hint: "Run vmlab images pull \(name).", data: ["image": .string(name)])
    }
    let dir = store.directory(of: record.id)
    let disk = dir.appending(path: "disk.raw")
    if !FileManager.default.fileExists(atPath: disk.path) {
      do {
        try FileManager.default.copyItem(
          at: images.imageDirectory(name).appending(path: raw), to: disk)
      } catch {
        throw VMLabError(
          code: .internal, message: "Cannot clone \(name) to \(disk.path): \(error)",
          hint: "Check free disk space and permissions under VMLAB_HOME.")
      }
    }
    let share = SharedDirSpec.of(record)
    try share?.checkHostDirectory(vmDirectory: dir)
    let key = try SSHKeys.generate(in: dir, comment: "vmlab-\(record.id)", runner: commands)
    let seed = CloudInitConfig(
      instanceID: record.id, hostname: Self.hostname(for: record), user: pulled.login.user,
      sshPublicKey: key, gui: try Self.guiStack(plan: plan, vmDirectory: dir),
      mounts: share.map {
        [GuestMount(tag: SharedDirSpec.tag, guestPath: $0.guestPath, kind: .virtiofs)]
      } ?? [],
      console: .hvc0,
      dhcpIdentifierMAC: record.network.mode == .disabled
        ? nil : VZRunnerConfig.stableMAC(for: record.id),
      rosetta: VZRunnerConfig.wantsRosetta(record)
    ).provisioned(record.provision)
    do {
      try CloudInit.makeSeed(
        seed, directory: dir.appending(path: "seed"), iso: dir.appending(path: "seed.iso"),
        runner: commands)
    } catch let error as VMLabError {
      throw error
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot write the cloud-init seed: \(error)",
        hint: "Check that the VM directory is writable.")
    }
  }

  /// R-504: the desktop and its in-guest VNC server, with the password in `<vm>/vnc.pass`, when
  /// the plan provisions one.
  static func guiStack(plan: Plan, vmDirectory: URL) throws(VMLabError) -> GUIStack? {
    guard plan.provisionsDesktop else { return nil }
    do {
      return try GUIStack.inGuestVNC(vmDirectory: vmDirectory)
    } catch let error as VMLabError {
      throw error
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot write the VNC password file: \(error)",
        hint: "Check that the VM directory is writable.")
    }
  }

  /// A DNS label from the VM's name (lowercase letters, digits and hyphens), else its id.
  static func hostname(for record: VMRecord) -> String {
    let mapped = String(
      record.name.lowercased().map {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : "-"
      }
    )
    let label = String(mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
    return label.isEmpty ? record.id : label
  }

  /// Launches the runner, then waits up to `leaseTimeout` for the NIC's DHCP lease and records
  /// it as `runtime.ip` (nil when none appeared; the guest still runs).
  public func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    let dir = store.directory(of: record.id)
    // VZ refuses to start with a missing shared directory; say which field instead.
    try SharedDirSpec.of(record)?.checkHostDirectory(vmDirectory: dir)
    // R-604: a kernel boot takes the image's (extracted, uncompressed) kernel when none was given.
    let boot =
      record.boot == nil
      ? nil : try await ImageStore(home: store.home).resolvingBoot(record.boot, image: record.image)
    let config = try VZRunnerConfig.linux(
      record: record, vmDirectory: dir, boot: boot,
      seed: FileManager.default.fileExists(atPath: dir.appending(path: "seed.iso").path))
    await serialChannels.drop(record.id)
    let handle = try await launcher.launch(vmDirectory: dir, config: config)
    var runtime = handle.runtime
    if let socket = config.serialSocket {
      runtime.serialSocket = socket
      // Connect now so serial.log follows the boot; a failure here is retried on attach.
      if record.features.contains(.serial) {
        _ = try? await serialChannels.channel(for: record.id, socket: socket, vmDirectory: dir)
      }
    }
    if case .nat(let mac?) = config.network.first {
      runtime.ip = await DHCPLeases.waitForIP(mac: mac, path: leasePath, timeout: leaseTimeout)
    }
    return runtime
  }

  public func stop(_ record: VMRecord) async throws(VMLabError) {
    let (client, pid) = target(record)
    // A paused guest cannot hear the power button; Lifecycle allows stop from paused.
    if try await client.status().state == .paused { try await client.resume() }
    try await client.stop()
    try await waitForExit(pid, within: stopTimeout, record: record, action: "stop")
    await serialChannels.drop(record.id)
  }

  public func kill(_ record: VMRecord) async throws(VMLabError) {
    let (client, pid) = target(record)
    do {
      try await client.kill()
    } catch  where error.code == .guestUnreachable || error.code == .timeout {
      if pid > 0 { Foundation.kill(pid, SIGKILL) }
    }
    try await waitForExit(pid, within: .seconds(15), record: record, action: "kill")
    await serialChannels.drop(record.id)
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
    await serialChannels.drop(record.id)
  }

  public func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM {
    let handle = try await VMLabVZ.attach(socketPath: target(record).client.socketPath)
    var serial: SerialChannel? = nil
    if record.features.contains(.serial) {
      let socket = record.runtime?.serialSocket ?? paths(record).serialSocket.path
      // nil when the socket does not answer: the channel reports guest_unreachable.
      serial = try? await serialChannels.channel(
        for: record.id, socket: socket, vmDirectory: store.directory(of: record.id))
    }
    let ssh = SSHEndpoint(runtime: record.runtime).map {
      SSHTarget(record: record, endpoint: $0, store: store)
    }
    return VZRunningVM(
      id: record.id, profile: profile, features: record.features, handle: handle, serial: serial,
      ssh: ssh)
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

/// The serial channel of each guest one backend drives, connected once and reused while it stays
/// connected (the runner serves one client at a time, as QEMU does).
final class VZSerialChannels: Sendable {
  private let channels = Mutex<[String: Task<SerialChannel, any Error>]>([:])

  /// The guest's connected channel, connecting (and logging to `<vm>/serial.log`) when there is
  /// none or the last one lost its socket.
  func channel(for id: String, socket: String, vmDirectory: URL) async throws -> SerialChannel {
    while true {
      let (task, fresh) = channels.withLock { tasks -> (Task<SerialChannel, any Error>, Bool) in
        if let cached = tasks[id] { return (cached, false) }
        let task = Task {
          let channel = SerialChannel(
            socketPath: socket, logURL: vmDirectory.appending(path: "serial.log"))
          try await channel.start()
          return channel
        }
        tasks[id] = task
        return (task, true)
      }
      let result = await task.result
      if case .success(let channel) = result, await channel.isConnected { return channel }
      // Failed, or connected once and since lost its socket: forget it (unless replaced).
      channels.withLock { if $0[id] == task { $0[id] = nil } }
      guard fresh else { continue }
      if case .failure(let error) = result { throw error }
      throw VMLabError(
        code: .guestUnreachable, message: "The serial socket closed as soon as it connected.",
        hint: "Check that the guest is running; see <vm>/vz.log.", data: ["socket": .string(socket)]
      )
    }
  }

  /// Forgets and stops the guest's channel (the guest stopped or is about to restart).
  func drop(_ id: String) async {
    let task = channels.withLock { $0.removeValue(forKey: id) }
    if let channel = try? await task?.value { await channel.stop() }
  }
}

/// A running VZ guest. Display (R-503) and checkpoints (R-605) are not wired yet.
public struct VZRunningVM: RunningVM {
  public let id: String
  public let profile: Profile
  public let features: [Feature]
  public let handle: VZRunnerHandle
  public let serial: SerialChannel?
  /// The guest's leased address on port 22 (R-400); nil when no lease was recorded.
  public let ssh: SSHTarget?

  public init(
    id: String, profile: Profile, features: [Feature], handle: VZRunnerHandle,
    serial: SerialChannel? = nil, ssh: SSHTarget? = nil
  ) {
    self.id = id
    self.profile = profile
    self.features = features
    self.handle = handle
    self.serial = serial
    self.ssh = ssh
  }

  public var display: DisplayEndpoint? { nil }
  public var gdb: GDBEndpoint? { nil }
  public var introspection: (any Introspection)? { nil }
  public var exec: any ExecChannel {
    if let ssh { return SSHExecChannel(target: ssh) }
    return NotYet(vm: id, channel: "exec", item: "R-400: no DHCP lease was recorded for SSH")
  }
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
