import Foundation

/// Where a VM is in its lifecycle (R-106 owns the transitions).
public enum VMState: String, CaseIterable, Codable, Sendable {
  case created, running, paused, stopped, suspended, broken

  /// Whether a guest in this state holds host memory and counts against the guest limits.
  public var isLive: Bool { self == .running || self == .paused }
}

/// The endpoints of a VM's engine process while it runs. Paths are absolute.
public struct VMRuntime: Codable, Sendable, Hashable {
  public var pid: Int32
  public var controlSocket: String
  public var qmpSocket: String?
  public var serialSocket: String?
  public var vncSocket: String?
  /// `unix:<path>` or `tcp:<host>:<port>`.
  public var gdbEndpoint: String?
  public var sshPort: Int?
  public var ip: String?
  /// The request's port forwards with the host ports actually bound on 127.0.0.1 (R-308; an
  /// ephemeral `host: nil` is resolved here). Nil when the engine forwards nothing.
  public var forwards: [PortForward]?

  public init(
    pid: Int32, controlSocket: String, qmpSocket: String? = nil, serialSocket: String? = nil,
    vncSocket: String? = nil, gdbEndpoint: String? = nil, sshPort: Int? = nil, ip: String? = nil,
    forwards: [PortForward]? = nil
  ) {
    self.pid = pid
    self.controlSocket = controlSocket
    self.qmpSocket = qmpSocket
    self.serialSocket = serialSocket
    self.vncSocket = vncSocket
    self.gdbEndpoint = gdbEndpoint
    self.sshPort = sshPort
    self.ip = ip
    self.forwards = forwards
  }
}

/// A checkpoint as the record lists it; the tree itself lives in `checkpoints.json` (R-800).
public struct CheckpointRef: Codable, Sendable, Hashable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// Where a cloned VM's disk came from (R-803): the source VM and, when cloned from one, the
/// checkpoint (its id and name at the time).
public struct CloneOrigin: Codable, Sendable, Hashable {
  public var vm: String
  public var checkpoint: String?
  public var checkpointName: String?
  public var at: Date

  public init(
    vm: String, checkpoint: String? = nil, checkpointName: String? = nil, at: Date = Date()
  ) {
    self.vm = vm
    self.checkpoint = checkpoint
    self.checkpointName = checkpointName
    self.at = at
  }
}

/// The contents of `vms/<id>/vm.json` (constraint C4). `features` is the resolved feature set the
/// plan granted.
public struct VMRecord: Codable, Sendable, Hashable {
  /// The version this build writes. Raise it only together with a migration in `StoreMigrations`
  /// and a fixture `Tests/Fixtures/store/vm-v<N>.json`.
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var id: String
  public var name: String
  public var profile: Profile
  public var guest: GuestSpec
  public var features: [Feature]
  public var resources: ResourceSpec
  public var image: String?
  public var network: NetworkSpec
  public var createdAt: Date
  public var state: VMState
  public var runtime: VMRuntime?
  public var checkpoints: [CheckpointRef]
  /// The plan the selector made when the VM was created, so `vm_inspect` can show it after a
  /// context reset. Absent from records written before it existed (additive: schema 1 still).
  public var plan: Plan?
  /// The VM this one was cloned from (R-803); nil for a VM made from an image.
  public var clonedFrom: CloneOrigin?
  /// The files the VM's disk reads through, nearest first (absolute paths): for a qcow2 clone the
  /// frozen layer in the source's `backing/` directory, then that layer's own backing files. Nil
  /// when none were recorded. `vm_lifecycle destroy` and `vmlab gc` read it (R-805).
  public var backingChain: [String]?
  /// How the guest boots (the request's `boot`); nil is from its disk. Additive: schema 1 still.
  public var boot: BootSpec?
  /// The request's `extra` (R-306: `qemuArgs`); nil when it had none. Additive: schema 1 still.
  public var extra: ExtraSpec?
  /// The request's `provision` (R-1001); nil when it had none. Additive: schema 1 still.
  public var provision: ProvisionSpec?
  /// The request's `share` (R-404); nil when it had none. Additive: schema 1 still.
  public var share: SharedDirSpec?

  public init(
    id: String, name: String? = nil, profile: Profile, guest: GuestSpec, features: [Feature],
    resources: ResourceSpec = ResourceSpec(), image: String? = nil,
    network: NetworkSpec = NetworkSpec(), createdAt: Date = Date(), state: VMState = .created,
    runtime: VMRuntime? = nil, checkpoints: [CheckpointRef] = [], plan: Plan? = nil,
    boot: BootSpec? = nil, extra: ExtraSpec? = nil, provision: ProvisionSpec? = nil,
    share: SharedDirSpec? = nil
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.name = name ?? id
    self.profile = profile
    self.guest = guest
    self.features = features
    self.resources = resources
    self.image = image
    self.network = network
    self.createdAt = createdAt
    self.state = state
    self.runtime = runtime
    self.checkpoints = checkpoints
    self.plan = plan
    self.boot = boot
    self.extra = extra
    self.provision = provision
    self.share = share
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion, id, name, profile, guest, features, resources, image, network, createdAt
    case state, runtime, checkpoints, plan, boot, extra, provision, share, clonedFrom, backingChain
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
    profile = try c.decode(Profile.self, forKey: .profile)
    guest = try c.decode(GuestSpec.self, forKey: .guest)
    features = try c.decodeIfPresent([Feature].self, forKey: .features) ?? []
    resources = try c.decodeIfPresent(ResourceSpec.self, forKey: .resources) ?? ResourceSpec()
    image = try c.decodeIfPresent(String.self, forKey: .image)
    network = try c.decodeIfPresent(NetworkSpec.self, forKey: .network) ?? NetworkSpec()
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    state = try c.decode(VMState.self, forKey: .state)
    runtime = try c.decodeIfPresent(VMRuntime.self, forKey: .runtime)
    checkpoints = try c.decodeIfPresent([CheckpointRef].self, forKey: .checkpoints) ?? []
    plan = try c.decodeIfPresent(Plan.self, forKey: .plan)
    boot = try c.decodeIfPresent(BootSpec.self, forKey: .boot)
    clonedFrom = try c.decodeIfPresent(CloneOrigin.self, forKey: .clonedFrom)
    backingChain = try c.decodeIfPresent([String].self, forKey: .backingChain)
    extra = try c.decodeIfPresent(ExtraSpec.self, forKey: .extra)
    provision = try c.decodeIfPresent(ProvisionSpec.self, forKey: .provision)
    share = try c.decodeIfPresent(SharedDirSpec.self, forKey: .share)
  }

  /// `vm-` plus six lowercase RFC 4648 base32 characters.
  public static func isValidID(_ id: String) -> Bool {
    guard id.hasPrefix("vm-") else { return false }
    let tail = id.utf8.dropFirst(3)
    return tail.count == 6 && tail.allSatisfy { StoreIDs.alphabet.utf8.contains($0) }
  }

  /// 1 to 64 letters, digits, `.`, `_` and `-`, starting with a letter or digit.
  public static func isValidName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 64 else {
      return false
    }
    func allowed(_ s: Unicode.Scalar) -> Bool {
      s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s))
    }
    return allowed(first)
      && name.unicodeScalars.allSatisfy { allowed($0) || $0 == "." || $0 == "_" || $0 == "-" }
  }
}

enum StoreIDs {
  static let alphabet = "abcdefghijklmnopqrstuvwxyz234567"

  static func random() -> String {
    var rng = SystemRandomNumberGenerator()
    let chars = Array(alphabet)
    return "vm-" + String((0..<6).map { _ in chars[Int(rng.next() % 32)] })
  }
}

/// Upgrades a raw `vm.json` from one schema version to the next. The registry maps a version N to
/// the step that turns an N document into an N+1 document (constraint C4: every prior version
/// loads).
public struct StoreMigrations: Sendable {
  public typealias Step = @Sendable (inout [String: JSONValue]) throws -> Void

  public var steps: [Int: Step]
  public var currentVersion: Int

  public init(steps: [Int: Step], currentVersion: Int) {
    self.steps = steps
    self.currentVersion = currentVersion
  }

  /// The released migrations. Version 1 is the first released schema; none yet.
  public static let released = StoreMigrations(
    steps: [:], currentVersion: VMRecord.currentSchemaVersion)

  /// Decodes `vm.json` content of any supported version into a current record.
  public func decode(_ data: Data, source: String) throws(VMLabError) -> VMRecord {
    let decoder = Store.decoder
    let document: [String: JSONValue]
    do {
      document = try decoder.decode([String: JSONValue].self, from: data)
    } catch {
      throw Store.corrupt(source, "not a JSON object: \(error)")
    }
    guard case .number(let raw) = document["schemaVersion"], let version = Int(exactly: raw),
      version >= 1
    else {
      throw Store.corrupt(source, "missing or invalid schemaVersion")
    }
    if version > currentVersion {
      throw VMLabError(
        code: .internal,
        message: "\(source) has schemaVersion \(version); this vmlab reads up to \(currentVersion)",
        hint: "Upgrade vmlab to manage this VM.",
        data: ["file": .string(source), "schemaVersion": .number(Double(version))])
    }
    var payload = data
    if version < currentVersion {
      var migrated = document
      for from in version..<currentVersion {
        guard let step = steps[from] else {
          throw Store.corrupt(source, "no migration from schemaVersion \(from)")
        }
        do { try step(&migrated) } catch {
          throw Store.corrupt(source, "migration from schemaVersion \(from) failed: \(error)")
        }
        migrated["schemaVersion"] = .number(Double(from + 1))
      }
      do { payload = try JSONEncoder().encode(migrated) } catch {
        throw Store.corrupt(source, "\(error)")
      }
    }
    do {
      return try decoder.decode(VMRecord.self, from: payload)
    } catch {
      throw Store.corrupt(source, "\(error)")
    }
  }
}

/// The VM store under `VMLAB_HOME` (Appendix F): `vms/<id>/vm.json`, written atomically (temp file
/// then `rename(2)`), with a per-VM `flock` on `locks/<id>.lock` so writers in two server
/// processes serialize. Reads take no lock: a rename is atomic, so a reader sees the old or the new
/// file, never a torn one.
public struct Store: Sendable {
  public static let recordFileName = "vm.json"

  public let home: URL
  public var migrations: StoreMigrations

  public init(home: URL, migrations: StoreMigrations = .released) {
    self.home = home
    self.migrations = migrations
  }

  /// `VMLAB_HOME`, or `~/.vmlab` when it is unset or empty.
  public static func defaultHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    environment["VMLAB_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vmlab")
  }

  public var vmsDirectory: URL { home.appending(path: "vms") }
  public var locksDirectory: URL { home.appending(path: "locks") }
  public var imagesDirectory: URL { home.appending(path: "images") }

  public func directory(of id: String) -> URL { vmsDirectory.appending(path: id) }
  public func recordURL(of id: String) -> URL {
    directory(of: id).appending(path: Self.recordFileName)
  }

  // MARK: Reading

  /// Every VM whose `vm.json` loads, sorted by creation time. A directory whose record does not
  /// load is skipped and reported in `unreadable`.
  public func list() throws(VMLabError) -> (records: [VMRecord], unreadable: [String: VMLabError]) {
    let ids: [String]
    do {
      ids = try FileManager.default.contentsOfDirectory(atPath: vmsDirectory.path)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return ([], [:])
    } catch {
      throw Self.ioError("list \(vmsDirectory.path)", error)
    }
    var records: [VMRecord] = []
    var unreadable: [String: VMLabError] = [:]
    for id in ids where VMRecord.isValidID(id) {
      do { records.append(try load(id: id)) } catch { unreadable[id] = error }
    }
    records.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    return (records, unreadable)
  }

  /// The record of `id`; `vm_not_found` when there is none.
  public func load(id: String) throws(VMLabError) -> VMRecord {
    let url = recordURL(of: id)
    let data: Data
    do {
      guard VMRecord.isValidID(id) else { throw CocoaError(.fileReadNoSuchFile) }
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      throw Self.notFound(id)
    } catch {
      throw Self.ioError("read \(url.path)", error)
    }
    return try migrations.decode(data, source: url.path)
  }

  /// The VM whose ID or name is `vm`.
  public func find(_ vm: String) throws(VMLabError) -> VMRecord {
    if VMRecord.isValidID(vm), let record = try? load(id: vm) { return record }
    if let record = try list().records.first(where: { $0.name == vm }) { return record }
    throw Self.notFound(vm)
  }

  /// Running and paused guests, (macOS, all), for `HostProbe.runningGuests` and the budgets.
  public func runningGuests() -> (macOS: Int, total: Int) {
    let live = ((try? list().records) ?? []).filter { $0.state.isLive }
    return (live.count(where: { $0.guest.os == .macos }), live.count)
  }

  // MARK: Writing

  /// Creates the directory and `vm.json` of a new VM with a fresh ID. `record.id` is replaced;
  /// `record.name`, when it equals the old ID or is empty, defaults to the new ID. Names are unique.
  public func create(_ record: VMRecord) throws(VMLabError) -> VMRecord {
    try withLock("store") { () throws(VMLabError) -> VMRecord in
      let existing = try list().records
      var new = record
      new.schemaVersion = VMRecord.currentSchemaVersion
      var id: String
      repeat {
        id = StoreIDs.random()
      } while FileManager.default.fileExists(
        atPath: directory(of: id).path)
      let defaultName = record.name.isEmpty || record.name == record.id
      new.id = id
      new.name = defaultName ? id : record.name
      try checkName(new.name, for: id, among: existing)
      do {
        try FileManager.default.createDirectory(
          at: directory(of: id), withIntermediateDirectories: true)
      } catch {
        throw Self.ioError("create \(directory(of: id).path)", error)
      }
      try withLock(id) { () throws(VMLabError) in try writeRecord(new) }
      return new
    }
  }

  /// Saves `record` over its existing `vm.json` under the VM's lock.
  public func save(_ record: VMRecord) throws(VMLabError) {
    _ = try update(id: record.id) { $0 = record }
  }

  /// Read-modify-write of one VM under its lock, so concurrent updates from two processes never
  /// lose each other's changes. A rename also takes the store lock (always after the VM's lock;
  /// `create` takes the store lock and then only the lock of an ID nobody else holds) so names stay
  /// unique.
  @discardableResult
  public func update(
    id: String, _ body: (inout VMRecord) throws(VMLabError) -> Void
  ) throws(VMLabError) -> VMRecord {
    try withLock(id) { () throws(VMLabError) -> VMRecord in
      let current = try load(id: id)
      var record = current
      try body(&record)
      record.id = id
      record.schemaVersion = VMRecord.currentSchemaVersion
      if record.name != current.name {
        try withLock("store") { () throws(VMLabError) in
          try checkName(record.name, for: id, among: try list().records)
          try writeRecord(record)
        }
      } else {
        try writeRecord(record)
      }
      return record
    }
  }

  /// Deletes the VM's directory. Engines must have stopped it first.
  public func remove(id: String) throws(VMLabError) {
    _ = try load(id: id)
    try withLock(id) { () throws(VMLabError) in
      do { try FileManager.default.removeItem(at: directory(of: id)) } catch {
        throw Self.ioError("remove \(directory(of: id).path)", error)
      }
    }
    try? FileManager.default.removeItem(at: locksDirectory.appending(path: "\(id).lock"))
  }

  private func checkName(
    _ name: String, for id: String, among records: [VMRecord]
  ) throws(VMLabError) {
    guard VMRecord.isValidName(name) else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "invalid VM name \"\(name)\"",
        hint: "Use 1 to 64 letters, digits, '.', '_' or '-', starting with a letter or digit.")
    }
    if VMRecord.isValidID(name), name != id {
      throw VMLabError.invalidRequest(
        field: "name", reason: "\"\(name)\" has the form of a VM ID",
        hint: "Choose a name that does not start with vm- and six base32 characters.")
    }
    if let other = records.first(where: { $0.name == name && $0.id != id }) {
      throw VMLabError.invalidRequest(
        field: "name", reason: "the name \"\(name)\" is taken by \(other.id)",
        hint: "Choose another name, or leave it out to use the VM's ID.")
    }
  }

  /// Writes `vm.json` through a temporary file in the same directory, `fsync`, then `rename(2)`.
  /// The caller holds the VM's lock.
  func writeRecord(_ record: VMRecord) throws(VMLabError) {
    let url = recordURL(of: record.id)
    let data: Data
    do { data = try Self.encoder.encode(record) } catch {
      throw Self.ioError("encode \(url.path)", error)
    }
    try Self.writeAtomically(data, to: url)
  }

  /// Writes `data` to `url` through a temporary file in the same directory, `fsync`, then
  /// `rename(2)`, so a reader sees the old or the new file, never a torn one.
  static func writeAtomically(_ data: Data, to url: URL) throws(VMLabError) {
    let temp = url.deletingLastPathComponent().appending(
      path: ".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw Self.posixError("create \(temp.path)") }
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    let synced = fsync(fd) == 0
    close(fd)
    guard written == data.count, synced else {
      let error = Self.posixError("write \(temp.path)")
      unlink(temp.path)
      throw error
    }
    guard rename(temp.path, url.path) == 0 else {
      let error = Self.posixError("rename \(temp.path)")
      unlink(temp.path)
      throw error
    }
  }

  /// Runs `body` holding an exclusive `flock` on `locks/<name>.lock` (a VM's id, or `store`).
  /// Not reentrant: `body` must not take the same lock again.
  func withLock<T>(
    _ name: String, _ body: () throws(VMLabError) -> T
  ) throws(VMLabError) -> T {
    do {
      try FileManager.default.createDirectory(
        at: locksDirectory, withIntermediateDirectories: true)
    } catch {
      throw Self.ioError("create \(locksDirectory.path)", error)
    }
    let path = locksDirectory.appending(path: "\(name).lock").path
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw Self.posixError("open \(path)") }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
      guard errno == EINTR else { throw Self.posixError("flock \(path)") }
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  // MARK: Coding and errors

  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  static func notFound(_ vm: String) -> VMLabError {
    VMLabError(
      code: .vmNotFound, message: "No VM named or with ID \"\(vm)\"",
      hint: "Call vm_list to see the VMs that exist.", data: ["vm": .string(vm)])
  }

  static func corrupt(_ source: String, _ reason: String) -> VMLabError {
    VMLabError(
      code: .internal, message: "Cannot read \(source): \(reason)",
      hint: "The VM's record is damaged; destroy the VM or restore vm.json from a backup.",
      data: ["file": .string(source), "reason": .string(reason)])
  }

  static func ioError(_ what: String, _ error: any Error) -> VMLabError {
    VMLabError(
      code: .internal, message: "Store I/O failed: \(what): \(error)",
      hint: "Check that VMLAB_HOME is writable and the disk is not full.",
      data: ["operation": .string(what)])
  }

  static func posixError(_ what: String) -> VMLabError {
    ioError(what, POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
  }
}
