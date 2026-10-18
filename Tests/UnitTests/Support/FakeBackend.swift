import Foundation
import Synchronization
import VMLabCore

/// A `Backend` that boots nothing: it records every call, hands out a fake runtime and offers every
/// channel, so tests drive the full lifecycle through Core. `fail(_:with:)` makes the next call of
/// one operation throw.
final class FakeBackend: Backend {
  enum Operation: String, Sendable {
    case create, start, stop, kill, pause, resume, reset, destroy, attach
  }

  struct Call: Sendable, Equatable {
    var operation: Operation
    var vm: String
    var state: VMState
  }

  let profile: Profile
  let store: Store
  private let state = Mutex<
    (
      calls: [Call], failures: [Operation: VMLabError], delay: Duration?,
      holdUntil: (@Sendable () -> Bool)?
    )
  >(([], [:], nil, nil))
  /// The forwarded SSH port the fake runtime reports; nil (the default) means no SSH endpoint.
  private let ssh = Mutex<Int?>(nil)

  func reportSSHPort(_ port: Int?) { ssh.withLock { $0 = port } }

  /// The engine snapshots of every VM this backend runs, bound to the VM's state per call.
  let snapshots = FakeCheckpoints()

  init(profile: Profile = .qemuHVF, store: Store) {
    self.profile = profile
    self.store = store
  }

  var calls: [Call] { state.withLock { $0.calls } }
  var operations: [Operation] { calls.map(\.operation) }

  func fail(_ operation: Operation, with error: VMLabError = FakeBackend.engineFailure) {
    state.withLock { $0.failures[operation] = error }
  }

  /// Makes `create` sleep, so a test can cancel it.
  func delayCreate(_ duration: Duration) { state.withLock { $0.delay = duration } }

  /// Makes `create` wait (polling, up to 10 s) until `condition` holds, so a test that needs
  /// something to happen during a create does not depend on how busy the machine is.
  func holdCreate(until condition: @escaping @Sendable () -> Bool) {
    state.withLock { $0.holdUntil = condition }
  }

  static let engineFailure = VMLabError(
    code: .engineError, message: "fake engine failure", hint: "none")

  private func record(_ operation: Operation, _ vm: VMRecord) throws(VMLabError) {
    let failure = state.withLock { s -> VMLabError? in
      s.calls.append(Call(operation: operation, vm: vm.id, state: vm.state))
      return s.failures.removeValue(forKey: operation)
    }
    if let failure { throw failure }
  }

  func create(_ record: VMRecord, plan: Plan) async throws(VMLabError) {
    try self.record(.create, record)
    let disk = store.directory(of: record.id).appending(path: "disk.raw")
    FileManager.default.createFile(atPath: disk.path, contents: Data())
    if let delay = state.withLock({ $0.delay }) { try? await Task.sleep(for: delay) }
    if let condition = state.withLock({ $0.holdUntil }) {
      let deadline = ContinuousClock.now + .seconds(10)
      while !condition(), ContinuousClock.now < deadline, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    try self.record(.start, record)
    return runtime(of: record)
  }

  func stop(_ record: VMRecord) async throws(VMLabError) { try self.record(.stop, record) }
  func kill(_ record: VMRecord) async throws(VMLabError) { try self.record(.kill, record) }
  func pause(_ record: VMRecord) async throws(VMLabError) { try self.record(.pause, record) }
  func resume(_ record: VMRecord) async throws(VMLabError) { try self.record(.resume, record) }

  func reset(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    try self.record(.reset, record)
    return runtime(of: record)
  }

  func destroy(_ record: VMRecord) async throws(VMLabError) { try self.record(.destroy, record) }

  func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM {
    try self.record(.attach, record)
    let dir = store.directory(of: record.id)
    return FakeRunningVM(
      id: record.id, profile: record.profile, features: record.features,
      serial: SerialChannel(vmDirectory: dir),
      display: DisplayEndpoint(
        address: .unixSocket(path: dir.appending(path: "vnc.sock").path), hostSide: true),
      gdb: GDBEndpoint(host: "127.0.0.1", port: 1234),
      introspection: FakeIntrospection(), exec: FakeExec(),
      checkpoints: snapshots.bound(to: record.state))
  }

  func checkpoints(_ record: VMRecord) async throws(VMLabError) -> any CheckpointProvider {
    snapshots.bound(to: record.state)
  }

  private func runtime(of record: VMRecord) -> VMRuntime {
    let dir = store.directory(of: record.id)
    return VMRuntime(
      pid: 4242, controlSocket: dir.appending(path: "control.sock").path,
      serialSocket: dir.appending(path: "serial.sock").path, gdbEndpoint: "tcp:127.0.0.1:1234",
      sshPort: ssh.withLock { $0 })
  }
}

struct FakeRunningVM: RunningVM {
  var id: String
  var profile: Profile
  var features: [Feature]
  var serial: SerialChannel?
  var display: DisplayEndpoint?
  var gdb: GDBEndpoint?
  var introspection: (any Introspection)?
  var exec: any ExecChannel
  var checkpoints: any CheckpointProvider
  var memoryDump: (any MemoryDumper)? = FakeMemoryDumper()
}

struct FakeExec: ExecChannel {
  func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
    ExecResult(exitCode: 0, stdout: request.command + "\n", stderr: "")
  }
}

struct FakeIntrospection: Introspection {
  func query(_ query: IntrospectionQuery) async throws(VMLabError) -> IntrospectionAnswer {
    switch query {
    case .memoryTree, .registers, .devices, .hmp: .text("fake \(query.name)")
    default: .json(.object(["query": .string(query.name)]))
    }
  }
}

/// Writes `size` zero bytes for a range, 1 KB for a full dump.
struct FakeMemoryDumper: MemoryDumper {
  func dump(_ request: MemoryDumpRequest) async throws(VMLabError) -> MemoryDumpResult {
    let bytes = request.size ?? 1024
    FileManager.default.createFile(
      atPath: request.path.path, contents: Data(count: Int(bytes)))
    return MemoryDumpResult(path: request.path, bytes: bytes, format: request.format)
  }
}

/// Engine snapshots by id. Bound to a VM state (`bound(to:)`) it follows QEMU's contract: live
/// checkpoints only while the guest runs, disk ones only while it is stopped, `wrong_state`
/// otherwise; an unknown or taken id is `invalid_request` with field `id`.
final class FakeCheckpoints: CheckpointProvider {
  struct Snapshot: Sendable, Equatable {
    var id: String
    var mode: CheckpointMode
  }

  final class Storage: Sendable {
    let value = Mutex<(snapshots: [Snapshot], restored: [String])>(([], []))
  }

  private let storage: Storage
  private let state: VMState?

  init() {
    storage = Storage()
    state = nil
  }

  private init(storage: Storage, state: VMState) {
    self.storage = storage
    self.state = state
  }

  /// A view on the same snapshots from a VM in `state`.
  func bound(to state: VMState) -> FakeCheckpoints {
    FakeCheckpoints(storage: storage, state: state)
  }

  var ids: [String] { storage.value.withLock { $0.snapshots.map(\.id) } }
  var snapshots: [Snapshot] { storage.value.withLock { $0.snapshots } }
  var restored: [String] { storage.value.withLock { $0.restored } }

  private func check(_ mode: CheckpointMode) throws(VMLabError) {
    guard let state else { return }
    if mode == .live, !state.isLive {
      throw VMLabError(
        code: .wrongState, message: "fake: live needs a running guest", hint: "start")
    }
    if mode == .disk, state.isLive {
      throw VMLabError(code: .wrongState, message: "fake: disk needs a stopped guest", hint: "stop")
    }
  }

  private static func missing(_ id: String) -> VMLabError {
    .invalidRequest(field: "id", reason: "no snapshot \(id)", hint: "none")
  }

  func create(id: String, mode: CheckpointMode) async throws(VMLabError) {
    try check(mode)
    try storage.value.withLock { (s) throws(VMLabError) in
      guard !s.snapshots.contains(where: { $0.id == id }) else {
        throw VMLabError.invalidRequest(field: "id", reason: "taken", hint: "none")
      }
      s.snapshots.append(Snapshot(id: id, mode: mode))
    }
  }

  func restore(id: String, mode: CheckpointMode) async throws(VMLabError) {
    try check(mode)
    try storage.value.withLock { (s) throws(VMLabError) in
      guard s.snapshots.contains(Snapshot(id: id, mode: mode)) else { throw Self.missing(id) }
      s.restored.append(id)
    }
  }

  func delete(id: String) async throws(VMLabError) {
    try storage.value.withLock { (s) throws(VMLabError) in
      guard s.snapshots.contains(where: { $0.id == id }) else { throw Self.missing(id) }
      s.snapshots.removeAll { $0.id == id }
    }
  }
}
