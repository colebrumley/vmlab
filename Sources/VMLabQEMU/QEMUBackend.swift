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
    try QEMUMachine.prepare(try request(record, plan: plan, seed: false))
  }

  public func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    var request = try request(record, plan: Self.plan(of: record), seed: true)
    if record.network.mode != .disabled { request.sshHostPort = try QEMUMachine.freeLoopbackPort() }
    let machine = try await Self.lift { try await QEMUMachine.launch(request) }
    machines.withLock { $0[record.id] = machine }
    return machine.runtime
  }

  public func stop(_ record: VMRecord) async throws(VMLabError) {
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
    try await Self.lift { try await machine.powerdown() }
    machines.withLock { _ = $0.removeValue(forKey: record.id) }
  }

  public func kill(_ record: VMRecord) async throws(VMLabError) {
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

  /// `system_reset`: the same process and endpoints, the guest rebooted.
  public func reset(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    let machine = try await machine(for: record)
    _ = try await Self.lift { try await machine.qmp.execute("system_reset") }
    return machine.runtime
  }

  public func destroy(_ record: VMRecord) async throws(VMLabError) {
    if let machine = machines.withLock({ $0.removeValue(forKey: record.id) }) {
      await machine.disconnect()
    }
  }

  public func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM {
    QEMURunningVM(
      record: record, machine: try await machine(for: record),
      checkpoints: try checkpointProvider(record))
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
        layout: layout, gdbPort: gdbPort, sshPort: record.runtime?.sshPort)
    }
    machines.withLock { $0[record.id] = machine }
    return machine
  }

  /// The plan a stored record was created from, as far as the launch needs it.
  static func plan(of record: VMRecord) -> Plan {
    Plan(
      profile: record.profile, guest: record.guest, resources: record.resources,
      features: record.features, estimatedStartupSeconds: 0)
  }

  private func request(
    _ record: VMRecord, plan: Plan, seed: Bool
  ) throws(VMLabError) -> QEMULaunchRequest {
    guard let image = record.image else {
      throw VMLabError.invalidRequest(
        field: "image", reason: "a QEMU guest boots from a pulled image",
        hint: "Create the VM with image: \"debian-13-arm64\".")
    }
    let base = try QEMUMachine.baseImage(named: image, in: images)
    let layout = layout(of: record.id)
    var config: CloudInitConfig?
    // The key is R-400's; until it exists the guest boots without a seed.
    let publicKey = layout.directory.appending(path: "id_ed25519.pub")
    if seed, let key = try? String(contentsOf: publicKey, encoding: .utf8) {
      config = CloudInitConfig(
        instanceID: record.id, hostname: record.name,
        user: images.pulled(image)?.login.user ?? "debian",
        sshPublicKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return QEMULaunchRequest(
      record: record, plan: plan, layout: layout, baseImage: base, seed: config,
      installation: try locate())
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

  public init(record: VMRecord, machine: QEMUMachine, checkpoints: any CheckpointProvider) {
    id = record.id
    profile = record.profile
    features = record.features
    self.machine = machine
    self.checkpoints = checkpoints
  }

  public var serial: SerialChannel? { machine.serial }
  public var display: DisplayEndpoint? {
    DisplayEndpoint(address: .unixSocket(path: machine.layout.vncSocket.path), hostSide: true)
  }
  public var gdb: GDBEndpoint? { machine.runtime.gdbEndpoint.flatMap(GDBEndpoint.init(runtime:)) }
  public var introspection: (any Introspection)? { QMPIntrospection(qmp: machine.qmp) }
  public var memoryDump: (any MemoryDumper)? { QMPMemoryDumper(qmp: machine.qmp) }
  public var exec: any ExecChannel { NotYetBuilt(vm: id, channel: "exec", item: "R-400") }
}

/// A channel the QEMU backend does not provide yet; every call is `guest_unreachable`.
struct NotYetBuilt: ExecChannel {
  let vm: String
  let channel: String
  let item: String

  var error: VMLabError {
    VMLabError(
      code: .guestUnreachable, message: "The \(channel) channel of \(vm) is not available yet.",
      hint: "This vmlab build does not provide it for QEMU guests (\(item)).",
      data: ["vm": .string(vm), "channel": .string(channel)])
  }

  func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult { throw error }
}
