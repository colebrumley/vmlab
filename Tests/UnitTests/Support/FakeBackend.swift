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
  private let state = Mutex<(calls: [Call], failures: [Operation: VMLabError], delay: Duration?)>(
    ([], [:], nil))
  /// The forwarded SSH port the fake runtime reports; nil (the default) means no SSH endpoint.
  private let ssh = Mutex<Int?>(nil)

  func reportSSHPort(_ port: Int?) { ssh.withLock { $0 = port } }

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
      introspection: FakeIntrospection(), exec: FakeExec(), checkpoints: FakeCheckpoints())
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
}

struct FakeExec: ExecChannel {
  func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult {
    ExecResult(exitCode: 0, stdout: request.command + "\n", stderr: "")
  }
}

struct FakeIntrospection: Introspection {
  func query(
    _ query: String, arguments: [String: JSONValue]
  ) async throws(VMLabError) -> JSONValue {
    .object(["query": .string(query)])
  }
}

final class FakeCheckpoints: CheckpointProvider {
  private let made = Mutex<[String]>([])
  var ids: [String] { made.withLock { $0 } }

  func create(id: String, mode: CheckpointMode) async throws(VMLabError) {
    made.withLock { $0.append(id) }
  }
  func restore(id: String, mode: CheckpointMode) async throws(VMLabError) {}
  func delete(id: String) async throws(VMLabError) { made.withLock { $0.removeAll { $0 == id } } }
}
