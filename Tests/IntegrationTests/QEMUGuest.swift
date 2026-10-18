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

  /// `requested` becomes the plan's `requested` features (R-504 installs a desktop for
  /// `gui_desktop`); with `sshKey`, `<vm>/id_ed25519` is generated first, so the guest boots
  /// with a cloud-init seed that authorizes it.
  static func boot(
    features: [Feature] = [.serial, .gui, .netNAT], requested: [Feature] = [], memoryGB: Int = 2,
    diskGB: Int = 8, sshKey: Bool = false
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
    let backend = QEMUBackend(profile: .qemuHVF, store: store)
    let registry = BackendRegistry()
    registry.register(backend)
    let manager = VMManager(store: store, backends: registry)
    let guest = GuestSpec(os: .linux, arch: .arm64)
    let plan = Plan(
      profile: .qemuHVF, guest: guest,
      resources: ResourceSpec(cpus: 2, memoryGB: memoryGB, diskGB: diskGB), features: features,
      requested: requested, estimatedStartupSeconds: 15)
    let created = try await manager.create(
      VMRecord(
        id: "", name: "it-\(n)", profile: .qemuHVF, guest: guest, features: features,
        image: "debian-13-arm64"), plan: plan)
    do {
      if sshKey { try generateKey(in: store.directory(of: created.id)) }
      guard let running = try await manager.perform(.start, on: created.id) else {
        throw VMLabError(code: .internal, message: "start returned no record", hint: "")
      }
      let machine = try await backend.machine(for: running)
      return QEMUGuest(
        home: home, manager: manager, backend: backend, record: running, machine: machine)
    } catch {
      try? await backend.kill(created)
      try? FileManager.default.removeItem(at: home)
      throw error
    }
  }

  /// `ssh-keygen -t ed25519` into `<dir>/id_ed25519` (and `.pub`).
  static func generateKey(in dir: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
    process.arguments = [
      "-q", "-t", "ed25519", "-N", "", "-C", "vmlab-test", "-f",
      dir.appending(path: "id_ed25519").path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw VMLabError(code: .internal, message: "ssh-keygen failed", hint: "")
    }
  }

  func shutdown() async {
    try? await backend.kill(record)
    try? FileManager.default.removeItem(at: home)
  }
}
