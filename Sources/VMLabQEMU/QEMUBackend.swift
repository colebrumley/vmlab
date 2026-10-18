import Darwin
import Foundation
import Synchronization
import VMLabCore

/// The `Backend` for `qemu-hvf` and `qemu-tcg` (one instance per profile). It keeps the connected
/// `QEMUMachine` of every guest it started or reattached to; a guest started by an earlier server
/// is reattached from its VM directory on first use.
public final class QEMUBackend: Backend {
  public let profile: Profile
  public let store: Store
  public let images: ImageStore
  /// The vmnet DHCP lease file (`DHCPLeases.defaultPath`), where a `net_fast` guest's address is.
  public let leasePath: String
  private let locate: @Sendable () throws(VMLabError) -> QEMUInstallation
  private let machines = Mutex<[String: QEMUMachine]>([:])
  /// CX-25: the attach in flight per VM, which every concurrent `machine(for:)` shares, so one
  /// monitor connection is made and watched.
  private let attaching = Mutex<[String: Task<QEMUMachine, any Error>]>([:])
  /// Replaces `QEMUMachine.attach` in tests.
  let attachHook = Mutex<(@Sendable (QEMULayout) async throws -> QEMUMachine)?>(nil)

  public init(
    profile: Profile, store: Store, images: ImageStore? = nil,
    installation: QEMUInstallation? = nil, leasePath: String = DHCPLeases.defaultPath
  ) {
    precondition(profile == .qemuHVF || profile == .qemuTCG, "QEMUBackend runs QEMU profiles")
    self.leasePath = leasePath
    self.profile = profile
    self.store = store
    self.images = images ?? ImageStore(home: store.home)
    if let installation {
      locate = { installation }
    } else {
      locate = { () throws(VMLabError) in try QEMUInstallation.locate() }
    }
  }

  public func layout(of id: String) -> QEMULayout {
    QEMULayout(vmDirectory: store.directory(of: id))
  }

  // MARK: Backend

  public func create(_ record: VMRecord, plan: Plan) async throws(VMLabError) {
    try QEMUMachine.prepare(try await request(record, plan: plan, seed: false))
  }

  public func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    var request = try await request(record, plan: Self.plan(of: record), seed: true)
    if Self.usesVmnet(record) {
      request.vmnet = true
    } else if record.network.mode != .disabled {
      request.sshHostPort = try QEMUMachine.freeLoopbackPort()
      request.forwards = try Self.resolveForwards(record.network.forwards)
    }
    if let segment = record.segment, record.network.mode != .disabled {
      let segments = SegmentStore(home: store.home)
      request.segment = QEMUSegmentNIC(
        portSocket: segments.portSocket(of: segment.segment, vm: record.id).path,
        switchSocket: segments.switchSocket(of: segment.segment).path, mac: segment.mac)
    }
    let machine = try await Self.lift { try await QEMUMachine.launch(request) }
    machines.withLock { $0[record.id] = machine }
    await watch(machine, of: record.id)
    return machine.runtime
  }

  public func stop(_ record: VMRecord) async throws(VMLabError) {
    try await stop(record, grace: nil)
  }

  /// ACPI power button, then up to `grace` (default 60 s, Appendix G) for QEMU to exit.
  public func stop(_ record: VMRecord, grace: Duration?) async throws(VMLabError) {
    // A guest whose process is already gone is stopped.
    let layout = layout(of: record.id)
    guard let pid = QEMUMachine.readPID(layout) ?? record.runtime?.pid,
      QEMUMachine.isAlive(pid, in: layout)
    else {
      if let machine = machines.withLock({ $0.removeValue(forKey: record.id) }) {
        await machine.disconnect()
      }
      return
    }
    let machine = try await machine(for: record)
    try await Self.lift { try await machine.powerdown(timeout: grace ?? .seconds(60)) }
    machines.withLock { _ = $0.removeValue(forKey: record.id) }
  }

  public func kill(_ record: VMRecord) async throws(VMLabError) {
    // A broken VM's QEMU may be hung: no QMP (whose handshake would wait), straight to SIGKILL.
    if record.state == .broken {
      if let machine = machines.withLock({ $0.removeValue(forKey: record.id) }) {
        await machine.disconnect()
      }
      // BH-3: only a pid that is still this VM's QEMU is signalled, not one a stale pid file
      // names after the pid was reused.
      let layout = layout(of: record.id)
      if let pid = QEMUMachine.readPID(layout) ?? record.runtime?.pid,
        EngineProcess.kill(pid, vmDirectory: layout.directory)
      {
        let deadline = ContinuousClock.now + .seconds(5)
        while QEMUMachine.isAlive(pid, in: layout), ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
      return
    }
    if let machine = try? await machine(for: record) {
      await machine.kill()
    } else if let pid = record.runtime?.pid ?? QEMUMachine.readPID(layout(of: record.id)) {
      EngineProcess.kill(pid, vmDirectory: layout(of: record.id).directory)
    }
    machines.withLock { _ = $0.removeValue(forKey: record.id) }
  }

  public func pause(_ record: VMRecord) async throws(VMLabError) {
    let machine = try await machine(for: record)
    _ = try await Self.lift { try await machine.qmp.execute("stop") }
  }

  public func resume(_ record: VMRecord) async throws(VMLabError) {
    let machine = try await machine(for: record)
    _ = try await Self.lift { try await machine.qmp.execute("cont") }
  }

  /// `system_reset`: the same process and endpoints (a debugger stays attached and QEMU keeps its
  /// breakpoints), the guest rebooted. With `boot.haltAtStart` the CPU is stopped first, so it
  /// waits at its first instruction as it did at start (R-703); otherwise it runs on.
  public func reset(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    let machine = try await machine(for: record)
    let halt = record.boot?.haltAtStart == true
    _ = try await Self.lift {
      if halt { _ = try await machine.qmp.execute("stop") }
      return try await machine.qmp.execute("system_reset")
    }
    return machine.runtime
  }

  public func destroy(_ record: VMRecord) async throws(VMLabError) {
    if let machine = machines.withLock({ $0.removeValue(forKey: record.id) }) {
      await machine.disconnect()
    }
  }

  public func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM {
    let machine = try await machine(for: record)
    let target = (SSHEndpoint(runtime: machine.runtime) ?? SSHEndpoint(runtime: record.runtime)).map
    {
      SSHTarget(record: record, endpoint: $0, store: store)
    }
    return QEMURunningVM(
      record: record, machine: machine, checkpoints: try checkpointProvider(record), ssh: target)
  }

  /// The forwarded port; for a `net_fast` (vmnet) guest, which has none, its DHCP lease, waited
  /// for up to `timeout` and recorded as `runtime.ip` while the same QEMU runs.
  public func sshEndpoint(_ record: VMRecord, timeout: Duration) async -> SSHEndpoint? {
    if let known =
      SSHEndpoint(runtime: record.runtime)
      ?? machines.withLock({ $0[record.id] }).flatMap({ SSHEndpoint(runtime: $0.runtime) })
    {
      return known
    }
    guard Self.usesVmnet(record), record.state.isLive, let runtime = record.runtime,
      let ip = await DHCPLeases.waitForIP(
        mac: QEMUCommandLine.mac(for: record.id), path: leasePath, timeout: timeout)
    else { return nil }
    _ = try? store.update(id: record.id) { current in
      guard current.state.isLive, var live = current.runtime, live.pid == runtime.pid,
        live.ip == nil
      else { return }
      live.ip = ip
      current.runtime = live
    }
    return SSHEndpoint(host: ip)
  }

  /// Checkpoints work on a stopped guest too (`qemu-img`), so they need no attach.
  public func checkpoints(_ record: VMRecord) async throws(VMLabError) -> any CheckpointProvider {
    try checkpointProvider(record)
  }

  func checkpointProvider(_ record: VMRecord) throws(VMLabError) -> QEMUCheckpoints {
    QEMUCheckpoints(backend: self, record: record, liveAllowed: liveSnapshotsAllowed(record))
  }

  /// Live checkpoints: always under TCG; under HVF when the plan granted `checkpoint_live` or the
  /// host fact `qemu_hvf_live_snapshot` (in this home's `host-facts.json`) is `yes`.
  public func liveSnapshotsAllowed(_ record: VMRecord) -> Bool {
    if profile == .qemuTCG || record.features.contains(.checkpointLive) { return true }
    let facts = try? SlowProbes.load(from: SlowProbes.url(home: store.home))
    return facts?.result(.qemuHVFLiveSnapshot) == .yes
  }

  /// The host's QEMU, located on first use.
  public func installation() throws(VMLabError) -> QEMUInstallation { try locate() }

  // MARK: Helpers

  /// The connected machine of a live guest, reattaching from its directory when needed.
  public func machine(for record: VMRecord) async throws(VMLabError) -> QEMUMachine {
    if let machine = machines.withLock({ $0[record.id] }), machine.isRunning,
      await machine.qmp.isConnected
    {
      return machine
    }
    let id = record.id
    let task = attaching.withLock { inFlight -> Task<QEMUMachine, any Error> in
      if let running = inFlight[id] { return running }
      let task = Task { [self] () async throws -> QEMUMachine in
        let layout = layout(of: id)
        let machine: QEMUMachine
        if let hook = attachHook.withLock({ $0 }) {
          machine = try await hook(layout)
        } else {
          let gdbPort = record.runtime?.gdbEndpoint.flatMap(GDBEndpoint.init(runtime:))?.port
          machine = try await QEMUMachine.attach(
            layout: layout, gdbPort: gdbPort, sshPort: record.runtime?.sshPort,
            forwards: record.runtime?.forwards)
        }
        machines.withLock { $0[id] = machine }
        await watch(machine, of: id)
        return machine
      }
      inFlight[id] = task
      return task
    }
    let result = await task.result
    attaching.withLock { if $0[id] == task { $0[id] = nil } }
    return try await Self.lift { try result.get() }
  }

  /// Dead-peer detection on the machine's QMP connection (R-1101): a QEMU that stops answering
  /// for 5 s marks the VM broken with the reason and is dropped from the cache.
  func watch(_ machine: QEMUMachine, of id: String) async {
    let store = store
    // R-304: QMP's asynchronous events (GUEST_PANICKED, RESET) go to the event log. Every QMP
    // monitor receives them, so with two servers connected only the holder of the VM's
    // `qmp-events` lock logs; another takes the lock at its next event once the holder is gone.
    let events = await machine.qmp.events()
    let log = EventLog(vmDirectory: store.directory(of: id))
    let lockPath = store.locksDirectory.appending(path: "\(id).qmp-events.lock").path
    let pid = machine.pid
    Task {
      await Self.forward(events, to: log, lockPath: lockPath) { [weak self] event in
        guard event.name == "SHUTDOWN" else { return }
        // QEMU exits after the guest powers off (no -no-shutdown): record it now, not at the
        // next reconcile.
        let deadline = ContinuousClock.now + .seconds(10)
        while QEMUMachine.isAlive(pid, in: machine.layout), ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(100))
        }
        guard !QEMUMachine.isAlive(pid, in: machine.layout) else { return }
        self?.machines.withLock { cached in
          if cached[id] === machine { cached[id] = nil }
        }
        await store.recordEngineExit(id: id, pid: pid, reason: Self.shutdownReason(event))
      }
    }
    let layout = machine.layout
    await machine.qmp.watchPeer(
      busyDirectory: layout.directory,
      onDead: { [weak self] reason in
        self?.machines.withLock { cached in
          if cached[id] === machine { cached[id] = nil }
        }
        await store.markBroken(id: id, reason: "qmp: \(reason)")
      },
      onClosed: { [weak self] in
        // CX-15: QEMU closed its monitor (SIGKILL, a crash, an exit after SHUTDOWN).
        self?.machines.withLock { cached in
          if cached[id] === machine { cached[id] = nil }
        }
        await Self.recordHangUp(
          store: store, id: id, pid: pid, isAlive: { QEMUMachine.isAlive($0, in: layout) })
      })
  }

  /// QEMU closed the QMP connection: once the process is gone (up to `exitWait`) the VM is
  /// `stopped` (`Store.recordEngineExit`, a no-op when a `SHUTDOWN` or an action recorded it
  /// first); a QEMU still there after that is `broken`, since it no longer serves its monitor.
  static func recordHangUp(
    store: Store, id: String, pid: Int32, isAlive: @Sendable (Int32) -> Bool,
    exitWait: Duration = .seconds(10), settle: Duration = .milliseconds(500)
  ) async {
    let deadline = ContinuousClock.now + exitWait
    while isAlive(pid), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard !isAlive(pid) else {
      await store.markBroken(
        id: id, reason: "qmp: QEMU (pid \(pid)) closed its monitor connection but still runs")
      return
    }
    // A SHUTDOWN seen just before names the cause better; let it record first.
    try? await Task.sleep(for: settle)
    await store.recordEngineExit(
      id: id, pid: pid, reason: "QEMU (pid \(pid)) exited; its QMP connection closed")
  }

  /// Appends every QMP event `QMPEventLogging` logs to `log` while this connection holds the
  /// lock at `lockPath` (taken at the first event it is free for, released when `events` ends).
  /// The lock holder also hands every event to `handle` (the backend's `SHUTDOWN` handling).
  static func forward(
    _ events: AsyncStream<QMPEvent>, to log: EventLog, lockPath: String,
    handle: @escaping @Sendable (QMPEvent) async -> Void = { _ in }
  ) async {
    var holder: FileLock?
    for await event in events {
      if holder == nil { holder = FileLock.tryLock(lockPath) }
      guard holder != nil else { continue }
      _ = try? await log.recordQMPEvent(event.name, data: .object(event.data))
      Task { await handle(event) }
    }
    holder?.unlock()
  }

  /// "the guest powered off (QMP SHUTDOWN, reason guest-shutdown)".
  static func shutdownReason(_ event: QMPEvent) -> String {
    let reason = event.data["reason"]?.stringValue
    let who = event.data["guest"] == .bool(false) ? "QEMU shut down" : "the guest powered off"
    return "\(who) (QMP SHUTDOWN" + (reason.map { ", reason \($0)" } ?? "") + ")"
  }

  /// Whether the guest's NIC is `vmnet-shared` (R-309): the request asked for `net_fast` and the
  /// plan granted it, which the matrix allows only as root or when `qemu_vmnet` probed `yes`.
  /// `net_fast` the profile merely has (it is `yes` there) does not switch a guest off
  /// user-mode networking, whose SSH and port forwards it relies on.
  static func usesVmnet(_ record: VMRecord) -> Bool {
    record.network.mode != .disabled && record.plan?.requests(.netFast) == true
  }

  /// `forwards` with every `host: nil` given a free loopback port (R-308). Ports are chosen by
  /// binding port 0, so two in one call differ; an explicit host port is kept as asked.
  static func resolveForwards(
    _ forwards: [PortForward], freePort: () throws(VMLabError) -> Int = QEMUMachine.freeLoopbackPort
  ) throws(VMLabError) -> [PortForward] {
    var taken = Set(forwards.compactMap(\.host))
    return try forwards.map { forward throws(VMLabError) in
      if forward.host != nil { return forward }
      var port = try freePort()
      for _ in 0..<8 where taken.contains(port) { port = try freePort() }
      taken.insert(port)
      return PortForward(guest: forward.guest, host: port)
    }
  }

  /// The plan a stored record was created from; for a record older than `VMRecord.plan`, one
  /// rebuilt as far as the launch needs it.
  static func plan(of record: VMRecord) -> Plan {
    record.plan
      ?? Plan(
        profile: record.profile, guest: record.guest, resources: record.resources,
        features: record.features, estimatedStartupSeconds: 0)
  }

  private func request(
    _ record: VMRecord, plan: Plan, seed: Bool
  ) async throws(VMLabError) -> QEMULaunchRequest {
    let boot = try await resolveBoot(record)
    let base: URL?
    if let image = record.image, boot.mode == .disk || images.pulled(image)?.format != .kernel {
      base = try QEMUMachine.baseImage(named: image, in: images)
    } else if boot.mode == .disk {
      throw VMLabError.invalidRequest(
        field: "image", reason: "a QEMU guest boots from a pulled image",
        hint: "Create the VM with image: \"debian-13-arm64\".")
    } else {
      base = nil
    }
    let layout = layout(of: record.id)
    var config: CloudInitConfig?
    // The key is R-400's; until it exists the guest boots without a seed.
    let publicKey = layout.directory.appending(path: "id_ed25519.pub")
    let share = SharedDirSpec.of(record)
    try share?.checkHostDirectory(vmDirectory: layout.directory)
    // BH-1: host paths in extra.qemuArgs pass the path policy again at start (a symlink may have
    // moved since create).
    let policy = PathPolicy.load(home: store.home)
    try record.extra?.checkHostPaths(policy: policy, vmlabHome: store.home)
    if let extra = record.extra {
      try Self.checkImageChains(
        extra, policy: policy, vmlabHome: store.home, qemuImg: try locate().qemuImg)
    }
    if seed, base != nil, let image = record.image,
      let key = try? String(contentsOf: publicKey, encoding: .utf8)
    {
      config = CloudInitConfig(
        instanceID: record.id, hostname: record.name,
        user: images.pulled(image)?.login.user ?? "debian",
        sshPublicKey: key.trimmingCharacters(in: .whitespacesAndNewlines),
        // R-504: the desktop only; QEMU's VNC socket is the display, so no VNC server.
        gui: plan.provisionsDesktop ? GUIStack(vncPassword: nil) : nil,
        mounts: share.map {
          [GuestMount(tag: SharedDirSpec.tag, guestPath: $0.guestPath, kind: .ninep)]
        } ?? []
      ).provisioned(record.provision)
      config?.applyTemplate(images.pulled(image)?.template)
      if let segment = record.segment, record.network.mode != .disabled {
        config?.segment = SegmentNIC(
          primaryMAC: QEMUCommandLine.mac(for: record.id), mac: segment.mac,
          address: segment.address, prefixLength: segment.prefixLength)
      }
    }
    return QEMULaunchRequest(
      record: record, plan: plan, layout: layout, baseImage: base, boot: boot, seed: config,
      installation: try locate(),
      sharedDirectory: share?.hostDirectory(vmDirectory: layout.directory))
  }

  /// An image a `file=` in `extra.qemuArgs` names may be a qcow2 whose header points elsewhere
  /// (a backing file, an external data file), which QEMU opens too: every file in its chain
  /// (`qemu-img info --backing-chain`) passes the same path policy. A file qemu-img cannot read
  /// is left to QEMU to refuse.
  static func checkImageChains(
    _ extra: ExtraSpec, policy: PathPolicy, vmlabHome: URL, qemuImg: URL
  ) throws(VMLabError) {
    for hostPath in extra.hostPaths
    where ["file", "filename"].contains(hostPath.key.split(separator: ".").last ?? "") {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: hostPath.path, isDirectory: &isDirectory),
        !isDirectory.boolValue,
        let output = try? info(URL(filePath: hostPath.path), qemuImg: qemuImg, ["--backing-chain"]),
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
      else { continue }
      let images = value.arrayValue ?? [value]
      var referenced: [String] = []
      for (index, image) in images.enumerated() {
        if index > 0, let name = image["filename"]?.stringValue { referenced.append(name) }
        if let dataFile = image["format-specific"]?["data"]?["data-file"]?.stringValue {
          referenced.append(dataFile)
        }
      }
      for name in referenced {
        // A relative name is relative to the image that names it; qemu-img prints it resolved.
        _ = try ExtraSpec.checkHostPath(
          name, field: "extra.qemuArgs[\(hostPath.index)]", policy: policy, vmlabHome: vmlabHome)
      }
    }
  }

  /// The record's boot spec with host paths checked; a kernel boot without a kernel path takes
  /// the image's kernel files, extracting them from the pulled image the first time.
  func resolveBoot(_ record: VMRecord) async throws(VMLabError) -> BootSpec {
    try await images.resolvingBoot(record.boot, image: record.image)
  }

  static func lift<T>(_ body: () async throws -> T) async throws(VMLabError) -> T {
    do {
      return try await body()
    } catch let error as VMLabError {
      throw error
    } catch {
      throw VMLabError(
        code: .engineError, message: "QEMU failed: \(error)",
        hint: "See qemu.log in the VM directory.",
        data: ["engine": .string("qemu"), "raw": .string("\(error)")])
    }
  }
}

/// A running QEMU guest's channels.
public struct QEMURunningVM: RunningVM {
  public let id: String
  public let profile: Profile
  public let features: [Feature]
  public let machine: QEMUMachine
  public let checkpoints: any CheckpointProvider
  /// Where SSH reaches the guest: its forwarded loopback port; nil with networking off.
  public let ssh: SSHTarget?

  public init(
    record: VMRecord, machine: QEMUMachine, checkpoints: any CheckpointProvider,
    ssh: SSHTarget? = nil
  ) {
    id = record.id
    profile = record.profile
    features = record.features
    self.machine = machine
    self.checkpoints = checkpoints
    self.ssh = ssh
  }

  public var serial: SerialChannel? { machine.serial }
  public var display: DisplayEndpoint? {
    DisplayEndpoint(address: .unixSocket(path: machine.layout.vncSocket.path), hostSide: true)
  }
  public var gdb: GDBEndpoint? { machine.runtime.gdbEndpoint.flatMap(GDBEndpoint.init(runtime:)) }
  public var introspection: (any Introspection)? { QMPIntrospection(qmp: machine.qmp) }
  public var memoryDump: (any MemoryDumper)? { QMPMemoryDumper(qmp: machine.qmp) }
  /// SSH through the forwarded port (R-400).
  public var exec: any ExecChannel {
    if let ssh { return SSHExecChannel(target: ssh) }
    return NoSSH(vm: id)
  }
  /// qemu-guest-agent over its virtio-serial port (R-403).
  public var agentExec: (any ExecChannel)? {
    GuestAgentExecChannel(agent: machine.agent, vmDirectory: machine.layout.directory)
  }
}

/// The SSH channel of a guest with no SSH endpoint (no network, or vmnet with no address yet):
/// every call is `guest_unreachable`, marked as never connected so `via: auto` takes the agent.
struct NoSSH: ExecChannel {
  let vm: String

  func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
    throw VMLabError(
      code: .guestUnreachable, message: "VM \(vm) has no network for SSH.",
      hint: "Run it with via: agent (exec_agent), or create the VM with a network.",
      data: [
        "vm": .string(vm), "tried": .array([.string("ssh")]),
        ExecFallback.connectedKey: .bool(false),
      ])
  }
}
