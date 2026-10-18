import Foundation
import Synchronization

// MARK: - Backend

/// One engine behind one profile (R-105). `vmlab` registers one per profile at startup
/// (`Backends.register`); Core drives them through `VMManager` and never names an engine.
///
/// Every call receives the VM's current record. A backend that needs the VM's directory gets the
/// `Store` when it is built and uses `Store.directory(of:)`. Calls are made only for transitions
/// `Lifecycle` allows; the manager records the target state after the call returns. A thrown error
/// leaves the record as it was.
public protocol Backend: Sendable {
  /// The profile this backend runs.
  var profile: Profile { get }

  /// Makes the engine's artifacts of a new VM (its disk, seed, clone). The record is already in the
  /// store, in state `created`, with the plan's profile, features and resources.
  func create(_ record: VMRecord, plan: Plan) async throws(VMLabError)
  /// Boots the guest (or restores a `suspended` one) and returns the engine's endpoints.
  func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime
  /// Asks the guest to shut down and waits for the engine process to exit.
  func stop(_ record: VMRecord) async throws(VMLabError)
  /// Ends the engine process at once.
  func kill(_ record: VMRecord) async throws(VMLabError)
  func pause(_ record: VMRecord) async throws(VMLabError)
  func resume(_ record: VMRecord) async throws(VMLabError)
  /// Hard reset of a running guest; returns the endpoints afterwards. The default kills and starts.
  func reset(_ record: VMRecord) async throws(VMLabError) -> VMRuntime
  /// Removes the engine's artifacts. The guest is not running (the manager kills it first); the
  /// manager removes the VM's directory and record afterwards.
  func destroy(_ record: VMRecord) async throws(VMLabError)
  /// Handles on the channels of a running or paused guest.
  func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM
  /// Where the guest's sshd is reached (R-400). The default reads the recorded runtime (the
  /// forwarded loopback port, else the IP). A backend that learns the address after `start`
  /// returns (a DHCP lease) overrides it and may wait up to `timeout` for it; nil when unknown.
  func sshEndpoint(_ record: VMRecord, timeout: Duration) async -> SSHEndpoint?
}

extension Backend {
  public func sshEndpoint(_ record: VMRecord, timeout: Duration) async -> SSHEndpoint? {
    SSHEndpoint(runtime: record.runtime)
  }

  public func reset(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    try await kill(record)
    var stopped = record
    stopped.state = .stopped
    stopped.runtime = nil
    return try await start(stopped)
  }
}

// MARK: - Channels

/// Where a guest's screen is served over VNC (R-503).
public struct DisplayEndpoint: Codable, Sendable, Hashable {
  public enum Address: Codable, Sendable, Hashable {
    case unixSocket(path: String)
    case tcp(host: String, port: Int)
  }

  public enum Auth: Codable, Sendable, Hashable {
    case none
    /// VNC Authentication with the password stored in this file (for example `<vm>/vnc.pass`).
    case vncPassword(file: String)
  }

  public var address: Address
  public var auth: Auth
  /// Whether the display is served by the host (QEMU's VNC) and so survives a crash of the guest's
  /// display stack; false for an in-guest VNC server or Screen Sharing.
  public var hostSide: Bool

  public init(address: Address, auth: Auth = .none, hostSide: Bool) {
    self.address = address
    self.auth = auth
    self.hostSide = hostSide
  }
}

/// A guest's GDB remote stub.
public struct GDBEndpoint: Codable, Sendable, Hashable {
  public var host: String
  public var port: Int

  public init(host: String, port: Int) {
    self.host = host
    self.port = port
  }

  /// Parses the `tcp:<host>:<port>` form of `VMRuntime.gdbEndpoint`; nil for anything else.
  public init?(runtime value: String) {
    guard value.hasPrefix("tcp:") else { return nil }
    let rest = value.dropFirst(4)
    guard let colon = rest.lastIndex(of: ":"), let port = Int(rest[rest.index(after: colon)...]),
      (1...65535).contains(port), colon != rest.startIndex
    else { return nil }
    self.init(host: String(rest[..<colon]), port: port)
  }
}

/// How `vm_exec` reaches the guest: SSH, the guest agent (R-403), or SSH when granted, else the
/// agent.
public enum ExecVia: String, CaseIterable, Codable, Sendable {
  case auto, ssh, agent
}

/// A command run in the guest (R-401): by the guest user's shell, in `cwd` with `env` added, as
/// `user` (sudo) when that is not the login user, killed with its whole process group after
/// `timeout`.
public struct ExecRequest: Sendable, Hashable {
  public var command: String
  public var stdin: Data?
  public var timeout: Duration
  public var cwd: String?
  public var env: [String: String]
  public var user: String?
  public var via: ExecVia

  public init(
    command: String, stdin: Data? = nil, timeout: Duration = .seconds(120), cwd: String? = nil,
    env: [String: String] = [:], user: String? = nil, via: ExecVia = .auto
  ) {
    self.command = command
    self.stdin = stdin
    self.timeout = timeout
    self.cwd = cwd
    self.env = env
    self.user = user
    self.via = via
  }
}

/// What a finished command left. Output over `ExecOutput.inlineLimit` keeps its head and tail
/// with `truncated` set, and the whole text is at `logPath`.
public struct ExecResult: Sendable, Hashable {
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String
  public var durationMs: Int
  public var truncated: Bool
  public var logPath: String?

  public init(
    exitCode: Int32, stdout: String, stderr: String, durationMs: Int = 0, truncated: Bool = false,
    logPath: String? = nil
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.durationMs = durationMs
    self.truncated = truncated
    self.logPath = logPath
  }
}

/// Runs commands in the guest: SSH (R-400) or a guest agent (R-403).
public protocol ExecChannel: Sendable {
  func run(_ request: ExecRequest) async throws(VMLabError) -> ExecResult
}

/// Read-only queries of the engine's view of a guest (R-311): `query` names one (`status`, `pci`,
/// ...) and `arguments` refine it.
public protocol Introspection: Sendable {
  func query(_ query: String, arguments: [String: JSONValue]) async throws(VMLabError) -> JSONValue
}

/// How a checkpoint is taken: the disk only, or the disk and the running guest's memory.
public enum CheckpointMode: String, CaseIterable, Codable, Sendable {
  case disk, live
}

/// The engine half of checkpoints (R-307, R-800 keeps the tree): takes, restores and deletes the
/// snapshot named by a checkpoint id.
public protocol CheckpointProvider: Sendable {
  func create(id: String, mode: CheckpointMode) async throws(VMLabError)
  func restore(id: String, mode: CheckpointMode) async throws(VMLabError)
  func delete(id: String) async throws(VMLabError)
}

/// A typed handle naming one channel of a `RunningVM` and the features that grant it (any one of
/// them suffices). Use the static members: `try vm.channel(.serial)`.
public struct Channel<Value>: Sendable {
  public let name: String
  public let features: [Feature]
  let value: @Sendable (any RunningVM) -> Value?

  init(name: String, features: [Feature], value: @escaping @Sendable (any RunningVM) -> Value?) {
    self.name = name
    self.features = features
    self.value = value
  }
}

extension Channel where Value == SerialChannel {
  public static var serial: Self { Self(name: "serial", features: [.serial]) { $0.serial } }
}

extension Channel where Value == DisplayEndpoint {
  public static var display: Self {
    Self(name: "display", features: [.gui, .guiPreboot, .guiDesktop]) { $0.display }
  }
}

extension Channel where Value == GDBEndpoint {
  public static var gdb: Self { Self(name: "gdb", features: [.gdb]) { $0.gdb } }
}

extension Channel where Value == any Introspection {
  public static var introspection: Self {
    Self(name: "introspection", features: [.introspection]) { $0.introspection }
  }
}

extension Channel where Value == any ExecChannel {
  /// SSH or the agent, whichever the backend offers (`via: auto`).
  public static var exec: Self { Self(name: "exec", features: [.execSSH, .execAgent]) { $0.exec } }
  /// SSH only (`via: ssh`).
  public static var execSSH: Self {
    Self(name: "exec_ssh", features: [.execSSH]) { $0.exec }
  }
  /// The guest agent only (`via: agent`); no backend offers it before R-403.
  public static var execAgent: Self {
    Self(name: "exec_agent", features: [.execAgent]) { _ in nil }
  }
}

extension Channel where Value == any CheckpointProvider {
  public static var checkpoints: Self {
    Self(name: "checkpoints", features: [.checkpointDisk, .checkpointLive]) { $0.checkpoints }
  }
}

/// A running or paused guest as its backend exposes it. Callers go through `channel(_:)`, which
/// refuses a channel the VM's plan did not grant; the raw properties are for backends.
public protocol RunningVM: Sendable {
  var id: String { get }
  var profile: Profile { get }
  /// The features the plan granted (`VMRecord.features`).
  var features: [Feature] { get }

  var serial: SerialChannel? { get }
  var display: DisplayEndpoint? { get }
  var gdb: GDBEndpoint? { get }
  var introspection: (any Introspection)? { get }
  var exec: any ExecChannel { get }
  var checkpoints: any CheckpointProvider { get }
}

extension RunningVM {
  /// The channel, when the plan granted one of its features: `capability_missing` otherwise (with
  /// the feature and the `vm_plan` hint), and `guest_unreachable` when it was granted but the engine
  /// has not brought it up.
  public func channel<Value>(_ channel: Channel<Value>) throws(VMLabError) -> Value {
    guard channel.features.contains(where: { features.contains($0) }) else {
      throw RunningVMErrors.capabilityMissing(channel, vm: id, profile: profile)
    }
    guard let value = channel.value(self) else {
      throw VMLabError(
        code: .guestUnreachable,
        message: "VM \(id) was granted the \(channel.name) channel but it is not available yet",
        hint: "Wait for the guest to finish booting and try again; vm_inspect shows its endpoints.",
        data: ["vm": .string(id), "channel": .string(channel.name)])
    }
    return value
  }
}

enum RunningVMErrors {
  static func capabilityMissing<Value>(
    _ channel: Channel<Value>, vm: String, profile: Profile
  ) -> VMLabError {
    let feature = channel.features[0].rawValue
    let alternatives = channel.features.map(\.rawValue)
    return VMLabError(
      code: .capabilityMissing,
      message: "VM \(vm) (\(profile.rawValue)) was not planned with \(feature); "
        + "its \(channel.name) channel is unavailable",
      hint: "Recreate the VM with require: [\"\(feature)\"]; call vm_plan first to see which "
        + "profile grants it.",
      data: [
        "feature": .string(feature), "profile": .string(profile.rawValue), "vm": .string(vm),
        "channel": .string(channel.name), "anyOf": .array(alternatives.map { .string($0) }),
      ])
  }
}

// MARK: - Registry

/// The backends this process can drive, one per profile. Thread-safe.
public final class BackendRegistry: Sendable {
  private let backends = Mutex<[Profile: any Backend]>([:])

  public init() {}

  /// Registers `backend` for its profile, replacing any earlier one.
  public func register(_ backend: any Backend) {
    backends.withLock { $0[backend.profile] = backend }
  }

  public func unregister(_ profile: Profile) {
    _ = backends.withLock { $0.removeValue(forKey: profile) }
  }

  /// The registered profiles, in rank order.
  public var profiles: [Profile] { backends.withLock { $0.keys.sorted() } }

  /// The backend of `profile`; `internal` when this build registered none.
  public func backend(for profile: Profile) throws(VMLabError) -> any Backend {
    guard let backend = backends.withLock({ $0[profile] }) else {
      throw VMLabError(
        code: .internal, message: "No backend is registered for profile \(profile.rawValue)",
        hint: "This vmlab build cannot run \(profile.rawValue) guests; run vmlab doctor.",
        data: ["profile": .string(profile.rawValue)])
    }
    return backend
  }
}

/// The process-wide registry that `vmlab` fills at startup.
public enum Backends {
  public static let shared = BackendRegistry()

  public static func register(_ backend: any Backend) { shared.register(backend) }

  public static func backend(for profile: Profile) throws(VMLabError) -> any Backend {
    try shared.backend(for: profile)
  }
}
