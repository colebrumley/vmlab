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
  /// CX-15: the runner process of every guest this backend started or attached, watched for its
  /// exit (guest shutdown, SIGKILL), which is recorded at once instead of at the next restart.
  let exitWatchers = VZExitWatchers()

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
  /// `hvc0`. A registered kernel-only image (R-305) booted with `boot.mode: kernel` has no disk
  /// to clone and gets none, nor a seed, as on QEMU (CX-30).
  /// The disk clone, `ssh-keygen` and `hdiutil` block: they run on a thread of their own, off the
  /// cooperative pool.
  public func create(_ record: VMRecord, plan: Plan) async throws(VMLabError) {
    try await OffPool.run("vmlab.vz.create") { () throws(VMLabError) in
      try self.createFiles(record, plan: plan)
    }
  }

  private func createFiles(_ record: VMRecord, plan: Plan) throws(VMLabError) {
    guard let name = record.image else { return }
    let images = ImageStore(home: store.home)
    if images.pulled(name)?.format == .kernel, record.boot?.mode == .kernel { return }
    guard let pulled = images.pulled(name), let raw = pulled.files["raw"] else {
      let kernelOnly = images.pulled(name)?.format == .kernel
      throw VMLabError(
        code: .imageNotFound,
        message: kernelOnly
          ? "Image \(name) is a kernel with no disk; it boots only with boot.mode kernel"
          : "Image \(name) has no pulled raw disk",
        hint: kernelOnly
          ? "Create the VM with boot: {mode: \"kernel\"}, or use an image with a disk."
          : "Run vmlab images pull \(name).",
        data: ["image": .string(name)])
    }
    let dir = store.directory(of: record.id)
    let disk = dir.appending(path: "disk.raw")
    let source = images.imageDirectory(name).appending(path: raw)
    let diskGB = ResourceLimits.resolve(record.resources, for: .linux).diskGB
    let diskBytes = try diskGB.map { (gb) throws(VMLabError) in
      try ResourceLimits.bytes(gb, unit: 1 << 30, field: "resources.diskGB")
    }
    if let diskGB, let diskBytes {
      try VZDisk.refuseShrink(
        current: VZDisk.size(of: source), toBytes: diskBytes, diskGB: diskGB, image: name)
    }
    if !FileManager.default.fileExists(atPath: disk.path) {
      do {
        try FileManager.default.copyItem(at: source, to: disk)
      } catch {
        throw VMLabError(
          code: .internal, message: "Cannot clone \(name) to \(disk.path): \(error)",
          hint: "Check free disk space and permissions under VMLAB_HOME.")
      }
    }
    // Sparse growth of the clone; cloud-init's growpart and resizefs grow the root on first boot.
    if let diskBytes { try VZDisk.grow(disk, toBytes: diskBytes) }
    let share = SharedDirSpec.of(record)
    try share?.checkHostDirectory(vmDirectory: dir)
    let key = try SSHKeys.generate(in: dir, comment: "vmlab-\(record.id)", runner: commands)
    var seed = CloudInitConfig(
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
    seed.applyTemplate(pulled.template)
    seed.rootConsole = plan.grants(.serial)
    if let segment = record.segment, record.network.mode != .disabled {
      seed.segment = SegmentNIC(
        primaryMAC: VZRunnerConfig.stableMAC(for: record.id), mac: segment.mac,
        address: segment.address, prefixLength: segment.prefixLength)
    }
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

  public func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    var warnings: [String] = []
    return try await start(record, warnings: &warnings)
  }

  /// Launches the runner, then waits up to `leaseTimeout` for the NIC's DHCP lease and records
  /// it as `runtime.ip` (nil when none appeared; the guest still runs). A disk boot boots the
  /// guest's own default kernel, read from its disk at every start (`stageDiskKernel`).
  public func start(_ record: VMRecord, warnings: inout [String]) async throws(VMLabError)
    -> VMRuntime
  {
    // A suspended guest comes back from its checkpoint: a held runner the restore loads into.
    if let held = try await startSuspended(record) { return held }
    let dir = store.directory(of: record.id)
    // VZ refuses to start with a missing shared directory; say which field instead.
    try SharedDirSpec.of(record)?.checkHostDirectory(
      vmDirectory: dir, policy: PathPolicy.load(home: store.home))
    // R-604: a kernel boot takes the image's (extracted, uncompressed) kernel when none was given.
    let boot =
      record.boot == nil
      ? nil : try await ImageStore(home: store.home).resolvingBoot(record.boot, image: record.image)
    let rootDisk = FileManager.default.fileExists(atPath: dir.appending(path: "disk.raw").path)
    let diskKernel =
      rootDisk && (boot?.mode ?? .disk) == .disk
      ? await stageDiskKernel(vmDirectory: dir, warnings: &warnings) : nil
    let config = try VZRunnerConfig.linux(
      record: record, vmDirectory: dir, boot: boot,
      seed: FileManager.default.fileExists(atPath: dir.appending(path: "seed.iso").path),
      rootDisk: rootDisk,
      segmentAttachSocket: record.segment.map {
        SegmentStore(home: store.home).attachSocket(of: $0.segment).path
      },
      diskKernel: diskKernel)
    await serialChannels.drop(record.id)
    ConsoleRun.markStart(vmDirectory: dir)
    let handle = try await launcher.launch(vmDirectory: dir, config: config)
    watchExit(id: record.id, pid: handle.runtime.pid)
    var runtime = handle.runtime
    if let socket = config.serialSocket {
      runtime.serialSocket = socket
      // Connect now so panic detection follows the boot; a failure here is retried on attach.
      if record.features.contains(.serial) {
        _ = try? await serialChannels.channel(for: record.id, socket: socket, vmDirectory: dir)
      }
    }
    if case .nat(let mac?) = config.network.first {
      runtime.ip = await DHCPLeases.waitForIP(mac: mac, path: leasePath, timeout: leaseTimeout)
    }
    return runtime
  }

  /// The guest's own default kernel, initrd and command line, read from `<vm>/disk.raw` and
  /// staged in `<vm>/boot-cache/` (`DiskBoot`), so the kernel speaks on `hvc0` from the first
  /// boot. Each start logs what it boots; a disk whose boot cannot be read boots through EFI
  /// (nil) with a warning that the console has the kernel's output only from the second boot.
  func stageDiskKernel(vmDirectory dir: URL, warnings: inout [String]) async -> DiskBoot.Staged? {
    let disk = dir.appending(path: "disk.raw")
    let cache = dir.appending(path: DiskBoot.cacheDirectory)
    let events = EventLog(vmDirectory: dir)
    do {
      let staged = try await OffPool.run("vmlab.vz.diskboot") { () throws(VMLabError) in
        try DiskBoot.stage(disk: disk, cache: cache)
      }
      try? await events.append(Self.bootEvent(staged))
      return staged
    } catch {
      let reason = error.data["raw"]?.stringValue ?? error.message
      let warning =
        "boot: the guest's kernel could not be read from its disk (\(reason)), so it boots "
        + "through EFI and GRUB: kernel messages and panics reach the serial console only once "
        + "GRUB passes console=hvc0, which cloud-init sets up on the first boot for the next"
      warnings.append(warning)
      try? await events.append(VMEvent(level: .warning, kind: .lifecycle, message: warning))
      return nil
    }
  }

  static func bootEvent(_ staged: DiskBoot.Staged) -> VMEvent {
    let what =
      ([staged.entry.kernel] + staged.entry.initrds).joined(separator: " and ")
    return VMEvent(
      kind: .lifecycle,
      message: "boot: \(what) from \(staged.entry.source), "
        + (staged.refreshed ? "staged anew" : "unchanged since the last start")
        + ", command line: \(staged.commandLine)",
      data: [
        "kernel": .string(staged.entry.kernel),
        "initrds": .array(staged.entry.initrds.map { .string($0) }),
        "source": .string(staged.entry.source), "commandLine": .string(staged.commandLine),
        "refreshed": .bool(staged.refreshed),
      ])
  }

  /// The recorded runtime's endpoint, else the guest's DHCP lease, waited for up to `timeout`
  /// and recorded as `runtime.ip` so `vm_inspect`, forwards and the display see it too (a lease
  /// that arrived after `start` stopped waiting).
  public func sshEndpoint(_ record: VMRecord, timeout: Duration) async -> SSHEndpoint? {
    if let known = SSHEndpoint(runtime: record.runtime) { return known }
    guard let ip = await lateLease(record, timeout: timeout) else { return nil }
    return SSHEndpoint(host: ip)
  }

  /// A live guest's lease that `start` did not record, persisted into its `vm.json` (under the
  /// VM's lock, only while the same runner is still the recorded one). Nil when the guest has no
  /// NAT NIC, is not running, or leased nothing within `timeout`.
  func lateLease(_ record: VMRecord, timeout: Duration) async -> String? {
    guard let runtime = record.runtime, record.state.isLive, record.network.mode != .disabled
    else { return nil }
    // Another process may have recorded it already.
    if let stored = try? store.load(id: record.id), stored.runtime?.pid == runtime.pid,
      let ip = stored.runtime?.ip, !ip.isEmpty
    {
      return ip
    }
    guard let config = try? VZRunnerConfig.read(from: paths(record).config),
      case .nat(let mac?) = config.network.first,
      let ip = await DHCPLeases.waitForIP(mac: mac, path: leasePath, timeout: timeout)
    else { return nil }
    _ = try? store.update(id: record.id) { current in
      guard current.state.isLive, var live = current.runtime, live.pid == runtime.pid,
        live.ip == nil
      else { return }
      live.ip = ip
      current.runtime = live
    }
    return ip
  }

  public func stop(_ record: VMRecord) async throws(VMLabError) {
    try await stop(record, grace: nil)
  }

  /// The runner's `stop`, then up to `grace` (default `stopTimeout`) for it to exit.
  public func stop(_ record: VMRecord, grace: Duration?) async throws(VMLabError) {
    let (client, pid) = target(record)
    // A paused guest cannot hear the power button; Lifecycle allows stop from paused.
    if try await client.status().state == .paused { try await client.resume() }
    try await client.stop()
    try await waitForExit(pid, within: grace ?? stopTimeout, record: record, action: "stop")
    await serialChannels.drop(record.id)
  }

  public func kill(_ record: VMRecord) async throws(VMLabError) {
    let (client, pid) = target(record)
    do {
      try await client.kill()
    } catch  where error.code == .guestUnreachable || error.code == .timeout {
      // BH-3: only a pid that is still this VM's runner, not one a stale vz.pid names.
      EngineProcess.kill(pid, vmDirectory: store.directory(of: record.id))
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
    if (try? await client.exit()) == nil {
      EngineProcess.kill(pid, vmDirectory: store.directory(of: record.id))
    }
    await serialChannels.drop(record.id)
  }

  public func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM {
    let handle = try await VMLabVZ.attach(socketPath: target(record).client.socketPath)
    if record.runtime?.pid == handle.pid { watchExit(id: record.id, pid: handle.pid) }
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
      ssh: ssh, checkpoints: VZCheckpoints(backend: self, record: record))
  }

  /// Records the runner's exit as soon as process `pid` ends (`Store.recordEngineExit`, which
  /// leaves a VM an action already moved, or one on another pid, alone).
  func watchExit(
    id: String, pid: Int32,
    isRunning: (@Sendable (Int32) -> Bool)? = nil
  ) {
    guard pid > 0 else { return }
    let store = store
    let directory = store.directory(of: id)
    let serial = serialChannels
    exitWatchers.watch(
      id: id, pid: pid,
      isRunning: isRunning ?? { EngineProcess.isRunning($0, vmDirectory: directory) }
    ) {
      await serial.drop(id)
      await store.recordEngineExit(
        id: id, pid: pid, reason: "the vmlab-vz runner (pid \(pid)) exited")
    }
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
    let directory = store.directory(of: record.id)
    while EngineProcess.isRunning(pid, vmDirectory: directory) {
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

/// Sizing of a VZ guest's disk to `resources.diskGB`: disks only grow.
enum VZDisk {
  /// The file's length in bytes; 0 when it cannot be read.
  static func size(of url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  /// `invalid_request` on `resources.diskGB` when the image's disk is already larger than asked.
  static func refuseShrink(current: UInt64, toBytes target: UInt64, diskGB: Int, image: String)
    throws(VMLabError)
  {
    guard current > target else { return }
    let imageGB = Int((current + (1 << 30) - 1) >> 30)
    throw VMLabError.invalidRequest(
      field: "resources.diskGB",
      reason: "\(diskGB) GB is smaller than image \(image)'s disk (\(imageGB) GB); disks only grow",
      hint: "Ask for at least \(imageGB) GB.")
  }

  /// Extends `url` to `target` bytes (`ftruncate`, so sparse on APFS); never shrinks it.
  static func grow(_ url: URL, toBytes target: UInt64) throws(VMLabError) {
    guard size(of: url) < target else { return }
    do {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.truncate(atOffset: target)
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot grow \(url.path) to \(target) bytes: \(error)",
        hint: "Check free disk space under VMLAB_HOME.")
    }
  }
}

/// One kqueue process source (`EVFILT_PROC`, `NOTE_EXIT`) per watched guest; a guest watched
/// again on the same pid keeps its source, on a new pid replaces it.
final class VZExitWatchers: Sendable {
  private struct Watch: @unchecked Sendable {
    var pid: Int32
    var source: any DispatchSourceProcess
  }
  private let watches = Mutex<[String: Watch]>([:])

  func watch(
    id: String, pid: Int32, isRunning: @escaping @Sendable (Int32) -> Bool,
    onExit: @escaping @Sendable () async -> Void
  ) {
    let fired = Mutex(false)
    let fire: @Sendable () -> Void = { [weak self] in
      guard
        fired.withLock({ was in
          defer { was = true }
          return !was
        })
      else { return }
      self?.watches.withLock { watches in
        if let watch = watches[id], watch.pid == pid {
          watch.source.cancel()
          watches[id] = nil
        }
      }
      Task { await onExit() }
    }
    let replaced = watches.withLock { watches -> Bool in
      if let current = watches[id] {
        if current.pid == pid { return false }
        current.source.cancel()
      }
      let source = DispatchSource.makeProcessSource(
        identifier: pid, eventMask: .exit, queue: .global())
      source.setEventHandler(handler: fire)
      watches[id] = Watch(pid: pid, source: source)
      source.resume()
      return true
    }
    // A process that ended before the source was registered never fires it.
    if replaced, !isRunning(pid) { fire() }
  }

  func stop(_ id: String) {
    watches.withLock { $0.removeValue(forKey: id)?.source.cancel() }
  }
}

/// The serial channel of each guest one backend drives, connected once and reused while it stays
/// connected (the runner serves one client at a time, as QEMU does).
final class VZSerialChannels: Sendable {
  private let channels = Mutex<[String: Task<SerialChannel, any Error>]>([:])

  /// The guest's connected channel (reading `<vm>/console.log`), connecting when there is
  /// none or the last one lost its socket.
  func channel(for id: String, socket: String, vmDirectory: URL) async throws -> SerialChannel {
    while true {
      let (task, fresh) = channels.withLock { tasks -> (Task<SerialChannel, any Error>, Bool) in
        if let cached = tasks[id] { return (cached, false) }
        let task = Task {
          // Offsets are positions in the runner's console.log, as for QEMU.
          let console = vmDirectory.appending(path: "console.log")
          let channel = SerialChannel(
            socketPath: socket, logURL: vmDirectory.appending(path: "serial.log"),
            consoleLog: console)
          // R-304, including panics logged while no channel was connected.
          await ConsolePanicWatch(vmDirectory: vmDirectory, console: console).attach(to: channel)
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

/// A running VZ guest. Display is Core's `DisplayEndpoint.forVM` (R-503).
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
    serial: SerialChannel? = nil, ssh: SSHTarget? = nil,
    checkpoints: (any CheckpointProvider)? = nil
  ) {
    self.id = id
    self.profile = profile
    self.features = features
    self.handle = handle
    self.serial = serial
    self.ssh = ssh
    self.provider = checkpoints
  }

  private let provider: (any CheckpointProvider)?

  public var display: DisplayEndpoint? { nil }
  public var gdb: GDBEndpoint? { nil }
  public var introspection: (any Introspection)? { nil }
  public var exec: any ExecChannel {
    if let ssh { return SSHExecChannel(target: ssh) }
    return NotYet(vm: id, channel: "exec", item: "R-400: no DHCP lease was recorded for SSH")
  }
  public var checkpoints: any CheckpointProvider {
    provider ?? NotYet(vm: id, channel: "checkpoints", item: "R-608")
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
