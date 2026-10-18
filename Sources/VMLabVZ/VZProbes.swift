import Darwin
import Foundation
import VMLabCore

/// The slow probe `vz_linux_live_snapshot` (R-608, Appendix E): boots a throwaway `vz-linux`
/// machine with the device set real guests get (`VZRunnerConfig.linux`) on a clone of a pulled
/// Linux image's raw disk (`unknown` when none is pulled), without network or seed. It pauses the machine, saves its state, ends
/// the runner, builds a held machine from the same configuration, restores the state into it and
/// resumes: `yes` when the restored machine runs, `no` when the save or the restore is refused.
/// Throws only when the machine could not be started at all (an unsigned runner, say).
public struct VZLiveSnapshotProbe: SlowProbeRunner {
  public var probe: SlowProbe { .vzLinuxLiveSnapshot }
  public var launcher: VZRunnerLauncher

  public init(launcher: VZRunnerLauncher = VZRunnerLauncher()) {
    self.launcher = launcher
  }

  public func run(_ context: SlowProbeContext) async throws(VMLabError) -> ProbeResult {
    _ = try await launcher.checkedRunner()
    let dir = Self.directory(home: context.home)
    let files = FileManager.default
    try? files.removeItem(at: dir)
    defer {
      try? files.removeItem(at: dir)
      rmdir(dir.deletingLastPathComponent().path)
    }
    // A guest that runs: an APFS clone of a pulled arm64 Linux raw disk (Apple's EFI powers a
    // machine off at once when it has nothing to boot).
    guard let source = Self.bootableDisk(home: context.home) else { return .unknown }
    do {
      try files.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      throw VZCheckpoints.ioError("prepare \(dir.path)", error)
    }
    try VZCheckpoints.clone(source, to: dir.appending(path: "disk.raw"))
    let guest = GuestSpec(os: .linux, arch: .arm64)
    let record = VMRecord(
      id: "probe-vz-live", profile: .vzLinux, guest: guest, features: [.serial],
      resources: ResourceSpec(cpus: 1, memoryGB: 1), network: NetworkSpec(mode: .disabled))
    let config = try VZRunnerConfig.linux(record: record, vmDirectory: dir, seed: false)
    return try await Self.saveAndRestore(
      launcher: launcher, vmDirectory: dir, config: config, settle: .seconds(5))
  }

  /// Starts `config` in `vmDirectory`, lets it run for `settle`, pauses and saves it, ends the
  /// runner, restores the state into a held machine built from the same configuration and
  /// resumes it: `yes` when it then runs, `no` when the framework refuses a step. Throws only
  /// when the first machine cannot start.
  static func saveAndRestore(
    launcher: VZRunnerLauncher, vmDirectory dir: URL, config: VZRunnerConfig, settle: Duration
  ) async throws(VMLabError) -> ProbeResult {
    let first = try await launcher.launch(vmDirectory: dir, config: config)
    let state = dir.appending(path: VZCheckpoints.stateFile).path
    var current = first
    defer { end(current) }
    do {
      try await Task.sleep(for: settle)
      try await first.client.pause()
      try await first.client.save(to: state)
    } catch {
      return .no
    }
    await endAndWait(first)
    let held: VZRunnerHandle
    do {
      held = try await launcher.launch(vmDirectory: dir, config: config, hold: true)
    } catch {
      return .no
    }
    current = held
    do {
      try await held.client.restore(from: state)
      try await held.client.resume()
      try await Task.sleep(for: .seconds(1))
      return try await held.client.status().state == .running ? .yes : .no
    } catch {
      return .no
    }
  }

  /// The raw disk of the first pulled arm64 Linux image, if any.
  static func bootableDisk(home: URL) -> URL? {
    let images = ImageStore(home: home)
    for name in ImageCatalogue.builtin.images.map(\.name) {
      guard let pulled = images.pulled(name), pulled.guest == GuestSpec(os: .linux, arch: .arm64),
        let raw = pulled.files["raw"]
      else { continue }
      let url = images.imageDirectory(name).appending(path: raw)
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  /// Under `home/probes/`, or under /tmp when that would make socket paths too long.
  static func directory(home: URL, name: String = "vz-live-snapshot-\(getpid())") -> URL {
    let preferred = home.appending(path: "probes/\(name)")
    if preferred.appending(path: "control.sock").path.utf8.count <= UnixStream.maxPathBytes {
      return preferred
    }
    return URL(filePath: "/tmp/vmlab-probe-\(name)")
  }

  @discardableResult
  static func end(_ handle: VZRunnerHandle) -> Bool {
    guard handle.pid > 0, LivenessProbe.processExists(handle.pid) else { return false }
    Foundation.kill(handle.pid, SIGKILL)
    return true
  }

  static func endAndWait(_ handle: VZRunnerHandle) async {
    _ = try? await handle.client.exit()
    let deadline = ContinuousClock.now + .seconds(10)
    while LivenessProbe.processExists(handle.pid), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    end(handle)
  }
}

/// The slow probe `vz_macos_live_snapshot` (R-608): a throwaway `tart clone` of the pulled
/// `macos-base` image (an APFS clone, seconds), run by our runner without network
/// (`VZRunnerConfig.macOS`), saved and restored as `VZLiveSnapshotProbe` does; the clone is
/// deleted after. `unknown` when tart or the image is missing, or two macOS guests already run
/// (the host's limit).
public struct VZMacLiveSnapshotProbe: SlowProbeRunner {
  public var probe: SlowProbe { .vzMacOSLiveSnapshot }
  public var launcher: VZRunnerLauncher
  public var image: String
  /// How long the guest boots before it is saved.
  public var settle: Duration

  public init(
    launcher: VZRunnerLauncher = VZRunnerLauncher(), image: String = "macos-base",
    settle: Duration = .seconds(20)
  ) {
    self.launcher = launcher
    self.image = image
    self.settle = settle
  }

  public func run(_ context: SlowProbeContext) async throws(VMLabError) -> ProbeResult {
    _ = try await launcher.checkedRunner()
    guard context.facts.runningMacOSGuests < ResourceLimits.defaults.maxMacOSGuests,
      let pulled = ImageStore(home: context.home).pulled(image), pulled.format == .tart,
      let tart = try? Tart.locate()
    else { return .unknown }
    let name = "vmlab-probe-mac-\(getpid())"
    let dir = VZLiveSnapshotProbe.directory(home: context.home, name: name)
    let files = FileManager.default
    try? files.removeItem(at: dir)
    try? await tart.delete(name)
    defer {
      try? tart.delete(name)
      try? files.removeItem(at: dir)
      rmdir(dir.deletingLastPathComponent().path)
    }
    do {
      try files.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      throw VZCheckpoints.ioError("prepare \(dir.path)", error)
    }
    let clone = try await tart.clone(pulled.tartVM ?? pulled.source, to: name)
    let tartConfig = try TartVMConfig.read(from: clone.directory)
    let record = VMRecord(
      id: name, profile: .vzMacOS, guest: GuestSpec(os: .macos, arch: .arm64), features: [],
      network: NetworkSpec(mode: .disabled))
    let config = VZRunnerConfig.macOS(record: record, clone: clone, config: tartConfig)
    return try await VZLiveSnapshotProbe.saveAndRestore(
      launcher: launcher, vmDirectory: dir, config: config, settle: settle)
  }
}

extension VMLabVZ {
  /// The slow probes this module owns, for `Engines` to register.
  public static var probeRunners: [any SlowProbeRunner] {
    [VZLiveSnapshotProbe(), VZMacLiveSnapshotProbe()]
  }
}
