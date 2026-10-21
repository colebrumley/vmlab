import Darwin
import Foundation
import Testing
import VMLabCore
import VMLabQEMU
import VMLabVZ

/// A throwaway `VMLAB_HOME` under /tmp (short, so socket paths fit `sockaddr_un`) whose `images/`
/// is a real directory holding links to each image in `~/.vmlab/images`, so a test can write a
/// template there without touching the shared cache. It registers the QEMU backends and, when the
/// signed runner is built, `VZBackend`. `shutdown()` kills every guest it knows, stops every segment
/// switch and removes the home; homes of killed runs are left to `TestHomeSweep`.
struct LabHome {
  /// `codesign` of one binary from two suites at once fails; sign once per test process.
  static let signOnce: Void = { try? VZRunnerIntegrationTests.signRunner() }()

  nonisolated(unsafe) static var counter = 0
  static let counterLock = NSLock()

  let home: URL
  let store: Store
  let registry: BackendRegistry
  let manager: VMManager
  let qemu: QEMUBackend
  let segments: SegmentStore

  init(tag: String = "h") throws {
    _ = TestHomeSweep.done
    let n = Self.counterLock.withLock {
      Self.counter += 1
      return Self.counter
    }
    home = URL(filePath: "/tmp/vmlab-test-\(getpid())-\(tag)\(n)")
    try? FileManager.default.removeItem(at: home)
    let images = home.appending(path: "images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let shared = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vmlab/images")
    for name in (try? FileManager.default.contentsOfDirectory(atPath: shared.path)) ?? [] {
      try FileManager.default.createSymbolicLink(
        at: images.appending(path: name), withDestinationURL: shared.appending(path: name))
    }
    store = Store(home: home)
    registry = BackendRegistry()
    qemu = QEMUBackend(profile: .qemuHVF, store: store)
    registry.register(qemu)
    if VZRunnerIntegrationTests.ready {
      _ = Self.signOnce
      registry.register(
        VZBackend(
          store: store, launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
          leaseTimeout: .seconds(90)))
      if VZMacGuestIntegrationTests.ready {
        registry.register(
          VZMacBackend(
            store: store,
            launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner),
            leaseTimeout: .seconds(240)))
      }
    }
    segments = SegmentStore(
      home: home,
      switchBinary: VZRunnerIntegrationTests.root.appending(path: ".build/debug/vmlab-switch").path)
    manager = VMManager(store: store, backends: registry, segments: segments)
  }

  static func plan(
    _ profile: Profile = .qemuHVF, features: [Feature] = [.serial, .execSSH, .netNAT],
    memoryGB: Int = 2, diskGB: Int = 8
  ) -> Plan {
    Plan(
      profile: profile, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: memoryGB, diskGB: diskGB), features: features,
      estimatedStartupSeconds: 20)
  }

  /// Creates and starts one guest; the start waits for SSH.
  func boot(
    name: String, image: String = "debian-13-arm64", plan: Plan = LabHome.plan(),
    network: NetworkSpec = NetworkSpec()
  ) async throws -> VMManager.Outcome {
    let created = try await manager.create(
      VMRecord(
        id: "", name: name, profile: plan.profile, guest: plan.guest, features: plan.features,
        image: image, network: network), plan: plan)
    return try await manager.runAdmitted(.start, on: created.id)
  }

  func exec(_ vm: String, _ command: String) async throws -> ExecResult {
    try await manager.attach(vm).channel(.exec).run(ExecRequest(command: command))
  }

  func shutdown() async {
    // A macOS guest's Tart clone goes only with a destroy.
    for record in (try? store.list().records) ?? [] where record.profile == .vzMacOS {
      _ = try? await manager.perform(.destroy, on: record.id, force: true)
    }
    for record in (try? store.list().records) ?? [] {
      if let backend = try? registry.backend(for: record.profile) {
        try? await backend.kill(record)
      }
      if let pid = record.runtime?.pid, pid > 0 { Darwin.kill(pid, SIGKILL) }
    }
    for segment in segments.list() { segments.stopSwitch(segment.name) }
    try? FileManager.default.removeItem(at: home)
  }
}
