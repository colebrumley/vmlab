import Foundation
import Testing
import VMLabCore
import VMLabVZ

@Suite(.serialized) struct VZRunnerIntegrationTests {
  static let root = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  static let runner = root.appending(path: ".build/debug/vmlab-vz").path
  static let image = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".vmlab/images/debian-13-arm64/disk.raw")
  static let ready =
    integrationEnabled && FileManager.default.fileExists(atPath: image.path)
    && FileManager.default.isExecutableFile(atPath: runner)

  /// `swift test` relinks the runner without its entitlement; sign it as scripts/sign.sh does.
  static func signRunner() throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/codesign")
    process.arguments = [
      "--force", "--sign", "-", "--entitlements",
      root.appending(path: "Sources/vmlab-vz/vmlab-vz.entitlements").path, runner,
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  /// R-600 Verify (integration): a Linux guest started through a detached runner keeps running
  /// when its launcher lets go; a fresh server (reconcile, then attach by socket path) sees it
  /// `running`, and `pause` works.
  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func runnerSurvivesItsLauncherAndReattaches() async throws {
    // Short home: unix socket paths must stay under 104 bytes.
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try Self.signRunner()

    let store = Store(home: home)
    let record = try store.create(
      VMRecord(
        id: "", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64), features: [],
        resources: ResourceSpec(cpus: 2, memoryGB: 2), image: "debian-13-arm64"))
    let dir = store.directory(of: record.id)
    try FileManager.default.copyItem(at: Self.image, to: dir.appending(path: "disk.raw"))

    let launcher = VZRunnerLauncher(runnerPath: Self.runner)
    var handle: VZRunnerHandle? = try await launcher.launch(
      vmDirectory: dir, config: try .linux(record: record, vmDirectory: dir, seed: false))
    let pid = try #require(handle?.pid)
    defer {
      kill(pid, SIGKILL)
    }
    #expect(handle?.state == .running)
    #expect(VZRunnerPaths(vmDirectory: dir).recordedPID() == pid)
    // Detached: its own process group (and it ignores SIGHUP), so a signal to the server's group
    // or the end of its terminal session does not take the guest down.
    #expect(getpgid(pid) == pid)
    #expect(getpgid(pid) != getpgrp())
    try store.update(id: record.id) {
      $0.state = .running
      $0.runtime = handle?.runtime
    }
    handle = nil  // the "server" goes away; nothing but vm.json remembers the runner

    // A new server: reconcile from disk, then reattach by the recorded socket path.
    let changes = try await store.reconcile()
    #expect(changes.isEmpty)
    let reloaded = try store.load(id: record.id)
    #expect(reloaded.state == .running)
    let runtime = try #require(reloaded.runtime)
    let attached = try await VMLabVZ.attach(runtime: runtime)
    #expect(attached.pid == pid)
    #expect(attached.state == .running)

    #expect(try await attached.client.pause().state == .paused)
    #expect(try await attached.client.status().state == .paused)
    await #expect {
      try await attached.client.pause()
    } throws: { ($0 as? VMLabError)?.code == .wrongState }
    #expect(try await attached.client.resume().state == .running)

    // kill stops the guest and the runner exits, removing its socket and pid file.
    #expect(try await attached.client.kill().state == .stopped)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while LivenessProbe.processExists(pid), clock.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!LivenessProbe.processExists(pid))
    #expect(!FileManager.default.fileExists(atPath: runtime.controlSocket))
    #expect(VZRunnerPaths(vmDirectory: dir).recordedPID() == nil)
  }

  /// An unsigned runner is refused before launch with the signing hint.
  @Test(.enabled(if: ready))
  func unsignedRunnerIsHostMissingTool() async throws {
    let copy = URL(filePath: "/tmp/vmlab-test-\(getpid())-unsigned")
    try? FileManager.default.removeItem(at: copy)
    defer { try? FileManager.default.removeItem(at: copy) }
    try FileManager.default.copyItem(at: URL(filePath: Self.runner), to: copy)
    let strip = Process()
    strip.executableURL = URL(filePath: "/usr/bin/codesign")
    strip.arguments = ["--force", "--sign", "-", copy.path]
    try strip.run()
    strip.waitUntilExit()
    #expect {
      try VZRunnerLauncher(runnerPath: copy.path).checkedRunner()
    } throws: { error in
      let error = error as? VMLabError
      return error?.code == .hostMissingTool && error?.hint == VZRunnerLauncher.signingHint
    }
  }

  /// The same path through Core: `VMManager` with `VZBackend` creates (cloning the pulled image),
  /// starts, and after a fresh manager reconciles, attaches, pauses, resumes and kills.
  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func backendDrivesTheLifecycle() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-b")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: Self.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    try Self.signRunner()

    let store = Store(home: home)
    func manager() -> VMManager {
      let registry = BackendRegistry()
      registry.register(
        VZBackend(store: store, launcher: VZRunnerLauncher(runnerPath: Self.runner)))
      return VMManager(store: store, backends: registry)
    }
    let plan = Plan(
      profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      resources: ResourceSpec(cpus: 2, memoryGB: 2, diskGB: 8), features: [.execSSH],
      estimatedStartupSeconds: 30)
    let draft = VMRecord(
      id: "", profile: .vzLinux, guest: plan.guest, features: [], image: "debian-13-arm64")
    let created = try await manager().create(draft, plan: plan)
    var started = try #require(try await manager().perform(.start, on: created.id))
    defer { if let pid = started.runtime?.pid { kill(pid, SIGKILL) } }
    #expect(started.state == .running)

    // A new server process would do exactly this: reconcile, then use a fresh manager.
    #expect(try await store.reconcile().isEmpty)
    let restarted = manager()
    let vm = try await restarted.attach(created.id)
    #expect(vm.profile == .vzLinux)
    started = try #require(try await restarted.perform(.pause, on: created.id))
    #expect(started.state == .paused)
    #expect(try await VMLabVZ.attach(runtime: try #require(started.runtime)).state == .paused)
    #expect(try await restarted.perform(.resume, on: created.id)?.state == .running)
    let killed = try #require(try await restarted.perform(.kill, on: created.id))
    #expect(killed.state == .stopped)
    #expect(killed.runtime == nil)
    #expect(try await restarted.perform(.destroy, on: created.id) == nil)
  }
}
