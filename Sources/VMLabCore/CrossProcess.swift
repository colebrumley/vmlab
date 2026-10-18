import Foundation
import Synchronization

/// An exclusive `flock(2)` on a file under `VMLAB_HOME/locks/` (R-1100). The lock belongs to the
/// open file description, so two `FileLock`s on one path exclude each other within a process as
/// across processes, and the kernel drops it when the holder exits, however it exits.
public final class FileLock: Sendable {
  public let path: String
  private let fd: Mutex<Int32>

  private init(path: String, fd: Int32) {
    self.path = path
    self.fd = Mutex(fd)
  }

  deinit { unlock() }

  private static func open(_ path: String) -> Int32? {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    return fd >= 0 ? fd : nil
  }

  /// The lock if nobody holds it now, else nil.
  public static func tryLock(_ path: String) -> FileLock? {
    guard let fd = open(path) else { return nil }
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      close(fd)
      return nil
    }
    return FileLock(path: path, fd: fd)
  }

  /// Waits for the lock, polling every `interval`; nil only when the file cannot be opened. A
  /// cancelled task keeps waiting (the callers hold no state a cancellation could undo).
  public static func lock(_ path: String, interval: Duration = .milliseconds(50)) async
    -> FileLock?
  {
    while true {
      if let lock = tryLock(path) { return lock }
      guard let probe = open(path) else { return nil }
      close(probe)
      do { try await Task.sleep(for: interval) } catch {
        // Cancelled, so `Task.sleep` returns at once: sleep on a thread of its own, never on
        // the cooperative pool's.
        await OffPool.sleep(interval)
      }
    }
  }

  /// Whether `path` can be opened (and created) for locking at all.
  static func canOpen(_ path: String) -> Bool {
    guard let fd = open(path) else { return false }
    close(fd)
    return true
  }

  /// Whether another holder has `path` locked (a shared lock cannot be taken).
  public static func isHeld(_ path: String) -> Bool {
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    while flock(fd, LOCK_SH | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      return errno == EWOULDBLOCK
    }
    flock(fd, LOCK_UN)
    return false
  }

  /// Replaces the file's contents (what the holder publishes to the others).
  public func write(_ data: Data) {
    fd.withLock { fd in
      guard fd >= 0 else { return }
      ftruncate(fd, 0)
      data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          let n = pwrite(fd, raw.baseAddress! + offset, raw.count - offset, off_t(offset))
          if n < 0 && errno == EINTR { continue }
          guard n > 0 else { return }
          offset += n
        }
      }
    }
  }

  /// Empties the file and releases the lock. Unlocking twice is a no-op.
  public func unlock() {
    fd.withLock { fd in
      guard fd >= 0 else { return }
      ftruncate(fd, 0)
      flock(fd, LOCK_UN)
      close(fd)
      fd = -1
    }
  }
}

/// The cross-process `StartGating` (R-1100): every `vmlab` process on `VMLAB_HOME` shares its
/// `parallelStarts` slots and its budget. A slot is an exclusive lock on
/// `locks/starts/slot-<n>.lock`, whose file holds the admitted guest as JSON while the start is
/// in flight; the limits are checked under `locks/starts/admit.lock` against `running()` (the
/// records, which every process writes) plus the guests in every slot another holder has locked,
/// so two servers cannot each pass a budget only one of them fits. A server that dies frees its
/// slots with it.
public final class FileStartGate: StartGating {
  public let directory: URL
  public let limits: ResourceLimits
  public let hostMemory: HostMemoryGuard?
  public let pollInterval: Duration
  private let held = Mutex<[UUID: FileLock]>([:])

  public init(
    home: URL, limits: ResourceLimits = .defaults, hostMemory: HostMemoryGuard? = nil,
    pollInterval: Duration = .milliseconds(50)
  ) {
    self.directory = home.appending(path: "locks/starts")
    self.limits = limits
    self.hostMemory = hostMemory
    self.pollInterval = pollInterval
  }

  var slotCount: Int { max(1, limits.parallelStarts) }

  func slotPath(_ n: Int) -> String { directory.appending(path: "slot-\(n).lock").path }
  var admitPath: String { directory.appending(path: "admit.lock").path }

  /// Starts in flight in this process.
  public var inFlight: Int { held.withLock { $0.count } }

  public func admit(
    _ guest: Inventory.Guest, running: @Sendable () -> Inventory, host: HostFacts
  ) async throws -> StartPermit {
    let (slot, index) = try await acquireSlot()
    guard let admission = await FileLock.lock(admitPath, interval: pollInterval) else {
      slot.unlock()
      throw Self.ioError(admitPath)
    }
    defer { admission.unlock() }
    let permit = StartPermit(guest: guest)
    do {
      try Task.checkCancellation()
      let pending = pendingGuests(excludingSlot: index)
      let live = running()
      let budget = Self.budgeted(live, pending: pending, excluding: guest)
      if let hostMemory {
        let liveIDs = Set(live.guests.compactMap(\.id))
        try hostMemory.check(
          guest, budget: budget,
          pending: pending.filter { $0.id.map { !liveIDs.contains($0) && $0 != guest.id } ?? true },
          limits: limits, host: host)
      } else {
        try limits.check(
          profile: guest.profile, memoryGB: guest.memoryGB, running: budget, host: host)
      }
    } catch {
      slot.unlock()
      throw error
    }
    slot.write((try? JSONEncoder().encode(Reservation(guest))) ?? Data())
    held.withLock { $0[permit.id] = slot }
    return permit
  }

  public func release(_ permit: StartPermit) async {
    held.withLock { $0.removeValue(forKey: permit.id) }?.unlock()
  }

  /// The first free slot, polling while all are taken; `internal` when no slot file can be
  /// opened, since then none will ever be free.
  private func acquireSlot() async throws -> (FileLock, Int) {
    while true {
      try Task.checkCancellation()
      for n in 0..<slotCount {
        if let lock = FileLock.tryLock(slotPath(n)) { return (lock, n) }
      }
      if !(0..<slotCount).contains(where: { FileLock.canOpen(slotPath($0)) }) {
        throw Self.ioError(slotPath(0))
      }
      try await Task.sleep(for: pollInterval)
    }
  }

  /// The guests of the starts other holders have admitted: every locked slot's contents.
  func pendingGuests(excludingSlot own: Int) -> [Inventory.Guest] {
    (0..<slotCount).filter { $0 != own }.compactMap { n -> Inventory.Guest? in
      let path = slotPath(n)
      guard FileLock.isHeld(path), let data = FileManager.default.contents(atPath: path),
        !data.isEmpty
      else { return nil }
      return (try? JSONDecoder().decode(Reservation.self, from: data))?.guest
    }
  }

  /// `running` plus the pending guests not yet live in it, without `guest` itself.
  static func budgeted(
    _ running: Inventory, pending: [Inventory.Guest], excluding guest: Inventory.Guest
  ) -> Inventory {
    let liveIDs = Set(running.guests.compactMap(\.id))
    let others = running.guests.filter { $0.id == nil || $0.id != guest.id }
    let inFlight = pending.filter {
      $0.id.map { !liveIDs.contains($0) && $0 != guest.id } ?? true
    }
    return Inventory(guests: others + inFlight)
  }

  /// A slot file's contents.
  struct Reservation: Codable {
    var id: String?
    var profile: Profile
    var os: GuestSpec.OS
    var memoryGB: Int
    var pid: Int32
    var directory: String?

    init(_ guest: Inventory.Guest) {
      id = guest.id
      profile = guest.profile
      os = guest.os
      memoryGB = guest.memoryGB
      pid = getpid()
      directory = guest.directory
    }

    var guest: Inventory.Guest {
      Inventory.Guest(id: id, profile: profile, os: os, memoryGB: memoryGB, directory: directory)
    }
  }

  static func ioError(_ path: String) -> VMLabError {
    VMLabError(
      code: .internal, message: "Cannot open the start lock \(path)",
      hint: "Check that VMLAB_HOME/locks is writable.", data: ["file": .string(path)])
  }
}

extension Store {
  /// Where a VM's operation lock lives: held for the whole of a lifecycle or checkpoint action,
  /// so two processes never drive one VM at once (R-1100). The record lock (`<id>.lock`) is only
  /// held while `vm.json` is rewritten.
  public func operationLockPath(of id: String) -> String {
    locksDirectory.appending(path: "\(id).op.lock").path
  }
}
