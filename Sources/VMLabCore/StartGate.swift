import Foundation

/// Admission to a guest start (R-107): a slot among `parallelStarts`, then the dynamic limits
/// (`limit_macos_guests`, `limit_memory`) checked against the running guests plus every start still
/// in flight, so concurrent starts cannot each pass a budget that only one of them fits.
///
/// `StartGate` is the in-process implementation. R-1100 adds a cross-process one (the same budget
/// across every `vmlab` process on the host) by conforming another type to this protocol.
public protocol StartGating: Sendable {
  /// Waits for a start slot, then checks the limits for `guest` against `running()` (read once the
  /// slot is held) plus the guests of the other admitted starts. On success the slot and `guest`'s
  /// memory stay reserved until `release(_:)`. Throws the `VMLabError` of the refused limit, or
  /// `CancellationError` when the task is cancelled while waiting.
  func admit(
    _ guest: Inventory.Guest, running: @Sendable () -> Inventory, host: HostFacts
  ) async throws -> StartPermit

  /// Frees the slot and the reservation of an admitted start. Releasing twice is a no-op.
  func release(_ permit: StartPermit) async
}

/// One admitted start, held from `admit` to `release`.
public struct StartPermit: Sendable, Hashable {
  public let id: UUID
  public let guest: Inventory.Guest

  public init(id: UUID = UUID(), guest: Inventory.Guest) {
    self.id = id
    self.guest = guest
  }
}

extension StartGating {
  /// `body` run under an admitted start; the permit is released when `body` returns or throws.
  public func withStart<T: Sendable>(
    _ guest: Inventory.Guest, running: @Sendable () -> Inventory, host: HostFacts,
    _ body: () async throws -> T
  ) async throws -> T {
    let permit = try await admit(guest, running: running, host: host)
    do {
      let value = try await body()
      await release(permit)
      return value
    } catch {
      await release(permit)
      throw error
    }
  }
}

extension Inventory.Guest {
  /// The guest a start of `record` adds: its profile, OS and memory (or the Appendix G default).
  public init(record: VMRecord) {
    self.init(
      id: record.id, profile: record.profile, os: record.guest.os,
      memoryGB: record.resources.memoryGB
        ?? ResourceLimits.defaultResources(for: record.guest.os).memoryGB ?? 0)
  }
}

/// The in-process `StartGating`: a FIFO semaphore of `limits.parallelStarts` slots plus the
/// reservations of admitted starts. One instance per process is the global gate (`shared`).
public actor StartGate: StartGating {
  public static let shared = StartGate()

  public nonisolated let limits: ResourceLimits
  private var admitted: [UUID: Inventory.Guest] = [:]
  private var slotsInUse = 0
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

  public init(limits: ResourceLimits = .defaults) {
    self.limits = limits
  }

  /// Starts admitted and not yet released.
  public var inFlight: Int { admitted.count }
  /// Starts waiting for a slot.
  public var waiting: Int { waiters.count }

  public func admit(
    _ guest: Inventory.Guest, running: @Sendable () -> Inventory, host: HostFacts
  ) async throws -> StartPermit {
    try await acquireSlot()
    let permit = StartPermit(guest: guest)
    do {
      // A waiter cancelled just as a slot was handed to it gives the slot back.
      try Task.checkCancellation()
      try limits.check(
        profile: guest.profile, memoryGB: guest.memoryGB,
        running: budgeted(running(), excluding: guest), host: host)
    } catch {
      releaseSlot()
      throw error
    }
    admitted[permit.id] = guest
    return permit
  }

  public func release(_ permit: StartPermit) {
    guard admitted.removeValue(forKey: permit.id) != nil else { return }
    releaseSlot()
  }

  /// `running` plus the admitted starts not yet visible in it, without `guest` itself (a record
  /// that is already live is not counted twice).
  private func budgeted(_ running: Inventory, excluding guest: Inventory.Guest) -> Inventory {
    let liveIDs = Set(running.guests.compactMap(\.id))
    let others = running.guests.filter { $0.id == nil || $0.id != guest.id }
    let pending = admitted.values.filter { $0.id.map { !liveIDs.contains($0) } ?? true }
    return Inventory(guests: others + pending)
  }

  private func acquireSlot() async throws {
    try Task.checkCancellation()
    if slotsInUse < max(1, limits.parallelStarts) && waiters.isEmpty {
      slotsInUse += 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append((id, continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  /// Hands the slot to the first waiter, or frees it.
  private func releaseSlot() {
    if waiters.isEmpty {
      slotsInUse -= 1
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}
