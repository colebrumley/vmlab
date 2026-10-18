import Darwin
import Foundation

/// A VM's place on a segment (R-901), kept in its `vm.json` so both backends can attach the
/// second NIC and write its static address without reading the segment's record.
public struct SegmentAttachment: Codable, Sendable, Hashable {
  public var segment: String
  /// The guest's static IPv4 address, e.g. `10.1.0.10`.
  public var address: String
  public var prefixLength: Int
  /// The segment NIC's MAC (`SegmentAttachment.mac(for:)`).
  public var mac: String

  public init(segment: String, address: String, prefixLength: Int = 24, mac: String) {
    self.segment = segment
    self.address = address
    self.prefixLength = prefixLength
    self.mac = mac
  }

  /// A locally administered unicast MAC for the segment NIC, derived from the VM id (FNV-1a) and
  /// distinct from either engine's NAT MAC, so a restarted guest keeps its NIC.
  public static func mac(for id: String) -> String {
    var hash: UInt32 = 2_166_136_261
    for byte in "segment/\(id)".utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    let bytes = [UInt8(hash >> 16 & 0xff), UInt8(hash >> 8 & 0xff), UInt8(hash & 0xff)]
    return (["52", "54", "5e"] + bytes.map { String(format: "%02x", $0) }).joined(separator: ":")
  }
}

/// One guest on a segment, in join order.
public struct SegmentMember: Codable, Sendable, Hashable {
  public var vm: String
  public var name: String
  public var address: String
  public var mac: String
  public var joinedAt: Date

  public init(vm: String, name: String, address: String, mac: String, joinedAt: Date) {
    self.vm = vm
    self.name = name
    self.address = address
    self.mac = mac
    self.joinedAt = joinedAt
  }
}

/// `segments/<name>/segment.json`: a private host-local Ethernet segment. Segment `index` is the
/// subnet `10.<index>.0.0/24`; guests get `.10` upward in join order (Appendix G).
public struct Segment: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1
  public static let firstHost = 10

  public var schemaVersion: Int
  public var name: String
  public var index: Int
  public var createdAt: Date
  /// Made for a fleet (`segment: auto`); the fleet's destroy removes it.
  public var auto: Bool
  public var members: [SegmentMember]

  public init(name: String, index: Int, createdAt: Date, auto: Bool = false) {
    self.schemaVersion = Self.currentSchemaVersion
    self.name = name
    self.index = index
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    self.auto = auto
    self.members = []
  }

  public var subnet: String { "10.\(index).0.0/24" }

  /// The lowest free address from `.10`, which is join order while nobody has left.
  func nextAddress() -> String? {
    let taken = Set(members.map(\.address))
    return (Self.firstHost...254).lazy.map { "10.\(index).0.\($0)" }.first { !taken.contains($0) }
  }

  /// The `net_segment` result form.
  public var json: JSONValue {
    .object([
      "name": .string(name), "subnet": .string(subnet), "auto": .bool(auto),
      "members": .array(
        members.map {
          .object(["vm": .string($0.name), "id": .string($0.vm), "ip": .string($0.address)])
        }),
    ])
  }
}

/// `VMLAB_HOME/segments/`: segment records, membership and the `vmlab-switch` process of each
/// segment (Appendix F). Read-modify-writes take `locks/segment-<name>.lock`; creating a segment
/// also takes `locks/segments.lock` so two segments never share a subnet.
public struct SegmentStore: Sendable {
  public static let recordFileName = "segment.json"

  public let home: URL
  /// The `vmlab-switch` binary; nil when it cannot be found.
  public var switchBinary: String?
  public var now: @Sendable () -> Date

  public init(
    home: URL, switchBinary: String? = SegmentStore.defaultSwitchPath(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.home = home
    self.switchBinary = switchBinary
    self.now = now
  }

  /// `vmlab-switch` beside the running executable.
  public static func defaultSwitchPath() -> String? {
    Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "vmlab-switch").path
  }

  /// The longest segment name, in characters.
  public static let maxNameLength = 32

  /// `[a-z0-9-]`, starting with a letter or digit, at most 32 characters (as `vmlab-switch`).
  public static func isValidName(_ name: String) -> Bool {
    guard let first = name.utf8.first, name.utf8.count <= maxNameLength, first != UInt8(ascii: "-")
    else {
      return false
    }
    return name.utf8.allSatisfy { c in
      (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
        || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-")
    }
  }

  public var directory: URL { home.appending(path: "segments") }
  public func directory(of name: String) -> URL { directory.appending(path: name) }
  public func recordURL(of name: String) -> URL {
    directory(of: name).appending(path: Self.recordFileName)
  }
  /// Guests' ports send frames here (unix datagram).
  public func switchSocket(of name: String) -> URL {
    directory(of: name).appending(path: "switch.sock")
  }
  /// A connection here hands the switch one end of a datagram `socketpair` (VZ guests).
  public func attachSocket(of name: String) -> URL {
    directory(of: name).appending(path: "attach.sock")
  }
  public func pidFile(of name: String) -> URL { directory(of: name).appending(path: "switch.pid") }
  public func logFile(of name: String) -> URL { directory(of: name).appending(path: "switch.log") }
  /// Where a QEMU guest's `-netdev dgram` binds its end.
  public func portSocket(of name: String, vm: String) -> URL {
    directory(of: name).appending(path: "ports").appending(path: "\(vm).sock")
  }

  // MARK: Records

  public func list() -> [Segment] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.sorted().compactMap { try? load($0) }
  }

  public func load(_ name: String) throws(VMLabError) -> Segment {
    try Self.check(name)
    guard let data = try? Data(contentsOf: recordURL(of: name)) else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "no segment named \(name)",
        hint: "net_segment list shows the segments; create makes one.")
    }
    do { return try Store.decoder.decode(Segment.self, from: data) } catch {
      throw Store.corrupt(recordURL(of: name).path, "\(error)")
    }
  }

  /// A new segment with the lowest free subnet index (1 to 254).
  @discardableResult
  public func create(_ name: String, auto: Bool = false) throws(VMLabError) -> Segment {
    try Self.check(name)
    let lock = Store(home: home)
    return try lock.withLock("segments") { () throws(VMLabError) -> Segment in
      if FileManager.default.fileExists(atPath: recordURL(of: name).path) {
        throw VMLabError.invalidRequest(
          field: "name", reason: "the segment \(name) already exists",
          hint: "Choose another name, or join it with requirements.network.segment.")
      }
      let used = Set(list().map(\.index))
      guard let index = (1...254).first(where: { !used.contains($0) }) else {
        throw VMLabError.invalidRequest(
          field: "name", reason: "all 254 segment subnets are in use",
          hint: "Destroy a segment you no longer need.")
      }
      let segment = Segment(name: name, index: index, createdAt: now(), auto: auto)
      try write(segment)
      return segment
    }
  }

  /// The segment `name`, created when it does not exist.
  public func ensure(_ name: String, auto: Bool = false) throws(VMLabError) -> Segment {
    if let segment = try? load(name) { return segment }
    do { return try create(name, auto: auto) } catch  where error.data["field"] == .string("name") {
      return try load(name)
    }
  }

  /// Adds `record` to the segment (created when missing) at the next free address; joining again
  /// returns the address it already has.
  public func join(_ name: String, vm record: VMRecord) throws(VMLabError) -> SegmentAttachment {
    let mac = SegmentAttachment.mac(for: record.id)
    let member = try joining(name) { (segment: inout Segment) throws(VMLabError) -> SegmentMember in
      if let index = segment.members.firstIndex(where: { $0.vm == record.id }) {
        segment.members[index].name = record.name
        return segment.members[index]
      }
      guard let address = segment.nextAddress() else {
        throw VMLabError.invalidRequest(
          field: "network.segment", reason: "segment \(name) has no free address",
          hint: "Use another segment.")
      }
      let member = SegmentMember(
        vm: record.id, name: record.name, address: address, mac: mac, joinedAt: now())
      segment.members.append(member)
      return member
    }
    let port = portSocket(of: name, vm: record.id).path
    guard port.utf8.count <= 103 else {
      try? leave(name, vm: record.id)
      throw VMLabError.invalidRequest(
        field: "network.segment",
        reason: "the segment port socket path is \(port.utf8.count) bytes; the limit is 103",
        hint: "Use a shorter VMLAB_HOME or segment name.")
    }
    return SegmentAttachment(segment: name, address: member.address, mac: member.mac)
  }

  /// `update` of the segment, created first when missing. A destroy that removed it between
  /// the create and the locked update (CX-18) is answered by creating it again.
  private func joining<T>(
    _ name: String, _ body: (inout Segment) throws(VMLabError) -> T
  ) throws(VMLabError) -> T {
    var attempt = 0
    while true {
      _ = try ensure(name)
      do { return try update(name, body) } catch {
        attempt += 1
        guard attempt < 3, (try? load(name)) == nil else { throw error }
      }
    }
  }

  /// Removes `vm` from the segment; a missing segment or member is not an error.
  public func leave(_ name: String, vm: String) throws(VMLabError) {
    guard (try? load(name)) != nil else { return }
    try update(name) { (segment: inout Segment) throws(VMLabError) in
      segment.members.removeAll { $0.vm == vm }
    }
    try? FileManager.default.removeItem(at: portSocket(of: name, vm: vm))
  }

  /// Stops the switch and removes the segment; `wrong_state` while it has members. The check
  /// and the removal hold `segment-<name>`'s lock (CX-18), so a join is either seen or comes
  /// after, onto a segment it recreates.
  public func destroy(_ name: String) throws(VMLabError) {
    try Self.check(name)
    try Store(home: home).withLock("segment-\(name)") { () throws(VMLabError) in
      try destroyLocked(name)
    }
  }

  private func destroyLocked(_ name: String) throws(VMLabError) {
    let segment = try load(name)
    if !segment.members.isEmpty {
      throw VMLabError(
        code: .wrongState,
        message: "Segment \(name) still has \(segment.members.count) member(s)",
        hint: "Destroy its VMs first (or the fleet that made it).",
        data: [
          "state": .string("in_use"), "legalActions": .array([]),
          "members": .array(segment.members.map { .string($0.name) }),
        ])
    }
    stopSwitch(name)
    do { try FileManager.default.removeItem(at: directory(of: name)) } catch {
      throw Store.ioError("remove \(directory(of: name).path)", error)
    }
  }

  @discardableResult
  func update<T>(
    _ name: String, _ body: (inout Segment) throws(VMLabError) -> T
  ) throws(VMLabError) -> T {
    try Store(home: home).withLock("segment-\(name)") { () throws(VMLabError) -> T in
      var segment = try load(name)
      let result = try body(&segment)
      try write(segment)
      return result
    }
  }

  func write(_ segment: Segment) throws(VMLabError) {
    let url = recordURL(of: segment.name)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent().appending(path: "ports"),
        withIntermediateDirectories: true)
      try Store.encoder.encode(segment).write(to: url, options: .atomic)
    } catch {
      throw Store.ioError("write \(url.path)", error)
    }
  }

  static func check(_ name: String) throws(VMLabError) {
    guard isValidName(name) else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "\"\(name)\" is not a segment name",
        hint: "Use lowercase letters, digits and '-', at most 32 characters.")
    }
  }

  // MARK: The switch process

  /// The pid of the segment's live switch, if any.
  public func switchPID(_ name: String) -> Int32? {
    guard let text = try? String(contentsOf: pidFile(of: name), encoding: .utf8),
      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
      kill(pid, 0) == 0 || errno == EPERM
    else { return nil }
    return pid
  }

  /// Starts `vmlab-switch <name>` detached (output to `switch.log`) unless one runs, and waits
  /// until its sockets exist. Concurrent starts of one segment's guests take
  /// `locks/switch-<name>.lock`, so only one switch is launched. `host_missing_tool` when the binary
  /// is missing. The wait runs on a thread of its own, off the cooperative pool.
  public func startSwitch(_ name: String, timeout: Duration = .seconds(10)) async throws(VMLabError)
  {
    _ = try load(name)
    let result: Result<Void, VMLabError> = await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        do throws(VMLabError) {
          try Store(home: home).withLock("switch-\(name)") { () throws(VMLabError) in
            try launchSwitch(name, timeout: timeout)
          }
          continuation.resume(returning: .success(()))
        } catch {
          continuation.resume(returning: .failure(error))
        }
      }
    }
    try result.get()
  }

  /// Whether the switch of `name` runs and has bound its sockets.
  public func switchReady(_ name: String) -> Bool {
    switchPID(name) != nil && FileManager.default.fileExists(atPath: attachSocket(of: name).path)
      && FileManager.default.fileExists(atPath: switchSocket(of: name).path)
  }

  private func launchSwitch(_ name: String, timeout: Duration) throws(VMLabError) {
    if switchReady(name) { return }
    guard let binary = switchBinary, FileManager.default.isExecutableFile(atPath: binary) else {
      throw VMLabError(
        code: .hostMissingTool, message: "The segment switch vmlab-switch is not built",
        hint: "Run scripts/build.sh; vmlab-switch is installed beside vmlab.",
        data: ["tool": .string("vmlab-switch"), "fix": .string("scripts/build.sh")])
    }
    let process = Process()
    process.executableURL = URL(filePath: binary)
    process.arguments = [name]
    var environment = ProcessInfo.processInfo.environment
    environment["VMLAB_HOME"] = home.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let log = FileHandle(
      fileDescriptor: open(
        logFile(of: name).path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644),
      closeOnDealloc: true)
    process.standardOutput = log
    process.standardError = log
    do { try process.run() } catch {
      throw VMLabError(
        code: .hostMissingTool, message: "Cannot launch \(binary): \(error)",
        hint: "Run scripts/build.sh.", data: ["tool": .string("vmlab-switch")])
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if switchReady(name) { return }
      if !process.isRunning { break }
      usleep(20_000)
    }
    let tail = (try? String(contentsOf: logFile(of: name), encoding: .utf8))?.suffix(2000) ?? ""
    throw VMLabError(
      code: .engineError, message: "vmlab-switch for segment \(name) did not come up",
      hint: "See \(logFile(of: name).path).",
      data: ["engine": .string("vmlab-switch"), "raw": .string(String(tail))])
  }

  /// SIGTERM to the segment's switch, then SIGKILL after two seconds.
  public func stopSwitch(_ name: String) {
    guard let pid = switchPID(name) else { return }
    kill(pid, SIGTERM)
    for _ in 0..<40 {
      if kill(pid, 0) != 0 { return }
      usleep(50_000)
    }
    kill(pid, SIGKILL)
  }
}
