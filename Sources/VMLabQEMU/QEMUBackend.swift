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
  private let locate: @Sendable () throws(VMLabError) -> QEMUInstallation
  private let machines = Mutex<[String: QEMUMachine]>([:])

  public init(
    profile: Profile, store: Store, images: ImageStore? = nil,
    installation: QEMUInstallation? = nil
  ) {
    precondition(profile == .qemuHVF || profile == .qemuTCG, "QEMUBackend runs QEMU profiles")
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
    guard let pid = QEMUMachine.readPID(layout(of: record.id)) ?? record.runtime?.pid,
      QEMUMachine.isAlive(pid)
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
      if let pid = QEMUMachine.readPID(layout(of: record.id)) ?? record.runtime?.pid,
        QEMUMachine.isAlive(pid)
      {
        Darwin.kill(pid, SIGKILL)
        let deadline = ContinuousClock.now + .seconds(5)
        while QEMUMachine.isAlive(pid), ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
      return
    }
    if let machine = try? await machine(for: record) {
      await machine.kill()
    } else if let pid = record.runtime?.pid ?? QEMUMachine.readPID(layout(of: record.id)),
      QEMUMachine.isAlive(pid)
    {
      Darwin.kill(pid, SIGKILL)
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
    let target = SSHEndpoint(runtime: machine.runtime).map {
      SSHTarget(record: record, endpoint: $0, store: store)
    }
    return QEMURunningVM(
      record: record, machine: machine, checkpoints: try checkpointProvider(record), ssh: target)
  }

  public func sshEndpoint(_ record: VMRecord, timeout: Duration) async -> SSHEndpoint? {
    SSHEndpoint(runtime: record.runtime)
      ?? machines.withLock({ $0[record.id] }).flatMap { SSHEndpoint(runtime: $0.runtime) }
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
    let layout = layout(of: record.id)
    let gdbPort = record.runtime?.gdbEndpoint.flatMap(GDBEndpoint.init(runtime:))?.port
    let machine = try await Self.lift {
      try await QEMUMachine.attach(
        layout: layout, gdbPort: gdbPort, sshPort: record.runtime?.sshPort,
        forwards: record.runtime?.forwards)
    }
    machines.withLock { $0[record.id] = machine }
    await watch(machine, of: record.id)
    return machine
  }

  /// Dead-peer detection on the machine's QMP connection (R-1101): a QEMU that stops answering
  /// for 5 s marks the VM broken with the reason and is dropped from the cache.
  func watch(_ machine: QEMUMachine, of id: String) async {
    let store = store
    await machine.qmp.watchPeer { [weak self] reason in
      self?.machines.withLock { cached in
        if cached[id] === machine { cached[id] = nil }
      }
      await store.markBroken(id: id, reason: "qmp: \(reason)")
    }
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
    }
    return QEMULaunchRequest(
      record: record, plan: plan, layout: layout, baseImage: base, boot: boot, seed: config,
      installation: try locate(),
      sharedDirectory: share?.hostDirectory(vmDirectory: layout.directory))
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
