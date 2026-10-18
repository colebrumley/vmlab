import Foundation
import Testing
import VMLabCore
import VMLabVZ

/// R-608 Verify (integration): a live checkpoint of a Linux guest with `yes > /dev/null` running
/// restores with that process still there; the slow probe answers and writes `host-facts.json`.
@Suite(.serialized) struct VZCheckpointIntegrationTests {
  static let ready = VZRunnerIntegrationTests.ready

  @Test(.enabled(if: ready), .timeLimit(.minutes(5)))
  func liveSnapshotProbeAnswersAndPersists() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-p")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    VZRunnerIntegrationTests.signRunner()
    let registry = SlowProbeRegistry()
    registry.register(
      VZLiveSnapshotProbe(launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner)))
    let probe = HostProbe(home: home)
    let outcomes = await registry.runAll(SlowProbeContext(home: home, facts: probe.gather()))
    let outcome = outcomes.first { $0.probe == .vzLinuxLiveSnapshot }
    print("vz_linux_live_snapshot: \(String(describing: outcome))")
    #expect(outcome?.status == .ran)
    #expect(outcome?.result == .yes)
    #expect(probe.gather().probe(.vzLinuxLiveSnapshot).isUnverified == false)
  }

  /// The macOS probe on a throwaway Tart clone; needs `macos-base` pulled and tart installed.
  @Test(
    .enabled(
      if: ready && pulled("macos-base")
        && FileManager.default.isExecutableFile(
          atPath: "/opt/homebrew/bin/tart")
    ), .timeLimit(.minutes(5)))
  func macOSLiveSnapshotProbeAnswers() async throws {
    let home = URL(filePath: "/tmp/vmlab-test-\(getpid())-m")
    try? FileManager.default.removeItem(at: home)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: "images"),
      withDestinationURL: VZRunnerIntegrationTests.image.deletingLastPathComponent()
        .deletingLastPathComponent())
    VZRunnerIntegrationTests.signRunner()
    let registry = SlowProbeRegistry()
    registry.register(
      VZMacLiveSnapshotProbe(
        launcher: VZRunnerLauncher(runnerPath: VZRunnerIntegrationTests.runner)))
    let facts = HostProbe(home: home).gather()
    let outcome = await registry.runAll(SlowProbeContext(home: home, facts: facts))
      .first { $0.probe == .vzMacOSLiveSnapshot }
    print("vz_macos_live_snapshot: \(String(describing: outcome))")
    #expect(outcome?.status == .ran)
  }

  @Test(.enabled(if: ready), .timeLimit(.minutes(8)))
  func liveCheckpointKeepsARunningProcess() async throws {
    let guest = try await VZGuest.boot(
      features: [.execSSH, .serial, .checkpointDisk, .checkpointLive], tag: "c")
    defer { guest.cleanUp() }
    let id = guest.id
    #expect(
      await guest.ssh("nohup yes > /dev/null 2>&1 < /dev/null & sleep 1; pgrep -x yes")?.status
        == 0)
    let made = try await guest.manager.createCheckpoint(id, name: "busy", mode: .live)
    #expect(made.node.mode == .live)
    #expect(
      FileManager.default.fileExists(
        atPath: guest.directory.appending(path: "checkpoints/\(made.node.id)/disk.raw").path))
    #expect(await guest.ssh("pkill -x yes; sleep 1; ! pgrep -x yes")?.status == 0)

    _ = try await guest.manager.restoreCheckpoint(id, name: "busy")
    let after = try guest.store.load(id: id)
    #expect(after.state == .running)
    #expect(after.runtime?.pid != nil && after.runtime?.pid != guest.record.runtime?.pid)
    let pgrep = await guest.ssh("pgrep -x yes", within: .seconds(60))
    #expect(pgrep?.status == 0, "yes is not running after the restore: \(pgrep?.output ?? "")")
    // The serial channel follows the new runner.
    let vm = try await guest.manager.attach(id)
    #expect(await (try vm.channel(.serial)).isConnected)
    try await guest.manager.perform(.kill, on: id)
  }
}
