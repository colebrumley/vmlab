import Darwin
import Foundation
import VMLabCore
import VMLabQEMU

/// A `debian-13-arm64` guest under `qemu-hvf`, created through `VMManager` and `QEMUBackend` in a
/// throwaway `VMLAB_HOME` under /tmp (short, so socket paths fit `sockaddr_un`). The home links
/// `~/.vmlab/images` instead of pulling again. `shutdown()` kills the guest and removes the home.
struct QEMUGuest {
  nonisolated(unsafe) static var counter = 0
  static let counterLock = NSLock()

  let home: URL
  let manager: VMManager
  let backend: QEMUBackend
  let record: VMRecord
  let machine: QEMUMachine
  /// The warnings of the start (R-400: `ssh_unreachable` when exec_ssh was granted and the guest
  /// never answered).
  var startWarnings: [String] = []

  /// `prepare` runs on the VM directory after create and before the first start (to drop an
  /// `id_ed25519.pub` there, say).
  static func boot(
    features: [Feature] = [.serial, .gui, .netNAT], memoryGB: Int = 2,
    prepare: ((URL) throws -> Void)? = nil, boot: BootSpec? = nil,
    network: NetworkSpec = NetworkSpec(), profile: Profile = .qemuHVF,
    guest: GuestSpec = GuestSpec(os: .linux, arch: .arm64), image: String = "debian-13-arm64",
    cpus: Int = 2
  ) async throws -> QEMUGuest {
    let n = counterLock.withLock {
      counter += 1
      return counter
    }
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-\(n)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".vmlab/images"))
    let store = Store(home: home)
    let backend = QEMUBackend(profile: profile, store: store)
    let registry = BackendRegistry()
    registry.register(backend)
    let manager = VMManager(store: store, backends: registry)
    let plan = Plan(
      profile: profile, guest: guest,
      resources: ResourceSpec(cpus: cpus, memoryGB: memoryGB, diskGB: 8), features: features,
      estimatedStartupSeconds: 15)
    let created = try await manager.create(
      VMRecord(
        id: "", name: "it-\(n)", profile: profile, guest: guest, features: features,
        image: image, network: network, boot: boot), plan: plan)
    do {
      try prepare?(store.directory(of: created.id))
      let outcome = try await manager.run(.start, on: created.id)
      guard let running = outcome.record else {
        throw VMLabError(code: .internal, message: "start returned no record", hint: "")
      }
      let machine = try await backend.machine(for: running)
      return QEMUGuest(
        home: home, manager: manager, backend: backend, record: running, machine: machine,
        startWarnings: outcome.warnings)
    } catch {
      try? await backend.kill(created)
      try? FileManager.default.removeItem(at: home)
      throw error
    }
  }

  func shutdown() async {
    try? await backend.kill(record)
    try? FileManager.default.removeItem(at: home)
  }
}
