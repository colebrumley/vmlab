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
    QEMURunningVM(record: record, machine: try await machine(for: record))
  }

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
    if seed, base != nil, let image = record.image,
      let key = try? String(contentsOf: publicKey, encoding: .utf8)
    {
      config = CloudInitConfig(
        instanceID: record.id, hostname: record.name,
        user: images.pulled(image)?.login.user ?? "debian",
        sshPublicKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return QEMULaunchRequest(
      record: record, plan: plan, layout: layout, baseImage: base, boot: boot, seed: config,
      installation: try locate())
  }

  /// The record's boot spec with host paths checked; a kernel boot without a kernel path takes
  /// the image's kernel files, extracting them from the pulled image the first time.
  func resolveBoot(_ record: VMRecord) async throws(VMLabError) -> BootSpec {
    var boot = record.boot ?? BootSpec()
    if boot.mode == .kernel, boot.kernel == nil {
      guard let image = record.image else {
        throw VMLabError.invalidRequest(
          field: "boot.kernel", reason: "kernel boot needs a kernel path or an image",
          hint: "Set boot.kernel, or name an image whose kernel vmlab can extract.")
      }
      var files = images.kernel(of: image)
      if files == nil {
        let store = images
        files = try await Self.lift { try await store.extractKernel(image) }
      }
      guard let files else { throw VMLabError(code: .internal, message: "no kernel", hint: "") }
      boot.kernel = files.kernel.path
      if boot.initrd == nil { boot.initrd = files.initrd?.path }
    }
    let paths: [(String, String?)] = [
      ("boot.kernel", boot.mode == .kernel ? boot.kernel : nil),
      ("boot.initrd", boot.mode == .kernel ? boot.initrd : nil),
      ("boot.dtb", boot.mode == .kernel ? boot.dtb : nil),
      ("boot.firmware", boot.mode == .firmware ? boot.firmware : nil),
      ("boot.binary", boot.mode == .binary ? boot.binary : nil),
    ]
    for case (let field, let path?) in paths
    where !FileManager.default.isReadableFile(atPath: path) {
      throw VMLabError.invalidRequest(
        field: field, reason: "\(path) is not a readable file",
        hint: "Give the absolute host path of an existing file.")
    }
    return boot
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

  public init(record: VMRecord, machine: QEMUMachine) {
    id = record.id
    profile = record.profile
    features = record.features
    self.machine = machine
  }

  public var serial: SerialChannel? { machine.serial }
  public var display: DisplayEndpoint? {
    DisplayEndpoint(address: .unixSocket(path: machine.layout.vncSocket.path), hostSide: true)
  }
  public var gdb: GDBEndpoint? { machine.runtime.gdbEndpoint.flatMap(GDBEndpoint.init(runtime:)) }
  public var introspection: (any Introspection)? { QMPIntrospection(qmp: machine.qmp) }
  public var exec: any ExecChannel { NotYetBuilt(vm: id, channel: "exec", item: "R-400") }
  public var checkpoints: any CheckpointProvider {
    NotYetBuilt(vm: id, channel: "checkpoints", item: "R-307")
  }
}

/// `query` runs QMP `query-<query>` (R-311 widens this).
struct QMPIntrospection: Introspection {
  let qmp: QMPClient

  func query(_ query: String, arguments: [String: JSONValue]) async throws(VMLabError) -> JSONValue
  {
    try await QEMUBackend.lift {
      try await qmp.execute("query-\(query)", arguments: arguments.isEmpty ? nil : arguments)
    }
  }
}

/// A channel the QEMU backend does not provide yet; every call is `guest_unreachable`.
struct NotYetBuilt: ExecChannel, CheckpointProvider {
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
  func create(id: String, mode: CheckpointMode) async throws(VMLabError) { throw error }
  func restore(id: String, mode: CheckpointMode) async throws(VMLabError) { throw error }
  func delete(id: String) async throws(VMLabError) { throw error }
}
