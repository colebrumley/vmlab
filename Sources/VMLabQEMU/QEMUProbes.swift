import Darwin
import Foundation
import VMLabCore

/// The slow probe `qemu_hvf_live_snapshot` (R-307, Appendix E): boots a tiny HVF guest with the
/// same device set as a real one, an empty qcow2 disk and no image, so edk2 drops to its UEFI
/// shell on the serial console. It then runs `snapshot-save` and `snapshot-load` and types into
/// the shell: `yes` when the shell answers after the load, `no` when either job fails, QEMU dies
/// or the guest stays silent. Throws only when the guest could not be booted at all.
public struct QEMULiveSnapshotProbe: SlowProbeRunner {
  public var probe: SlowProbe { .qemuHVFLiveSnapshot }
  public var installation: QEMUInstallation?
  public var bootTimeout: Duration = .seconds(60)
  public var jobTimeout: Duration = .seconds(120)

  public init(installation: QEMUInstallation? = nil) {
    self.installation = installation
  }

  public func run(_ context: SlowProbeContext) async throws(VMLabError) -> ProbeResult {
    guard context.facts.qemu.present, context.facts.qemu.accelerators.contains("hvf") else {
      return .unknown
    }
    let installation: QEMUInstallation
    if let given = self.installation {
      installation = given
    } else {
      installation = try QEMUInstallation.locate()
    }
    let layout = Self.layout(home: context.home)
    let files = FileManager.default
    try? files.removeItem(at: layout.directory)
    defer {
      try? files.removeItem(at: layout.directory)
      // `probes/` itself goes when this was its last guest.
      rmdir(layout.directory.deletingLastPathComponent().path)
    }
    do {
      try files.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    } catch {
      throw QEMUMachine.ioError("create \(layout.directory.path)", error)
    }
    let base = layout.directory.appending(path: "base.qcow2")
    try await QEMUMachine.run(
      installation.qemuImg, ["create", "-q", "-f", "qcow2", base.path, "64M"],
      step: "qemu-img create")
    let guest = GuestSpec(os: .linux, arch: .arm64)
    let resources = ResourceSpec(cpus: 1, memoryGB: 1, diskGB: 1)
    let record = VMRecord(
      id: "probe-live-snapshot", profile: .qemuHVF, guest: guest, features: [.serial],
      resources: resources, network: NetworkSpec(mode: .disabled))
    let plan = Plan(
      profile: .qemuHVF, guest: guest, resources: resources, features: [.serial],
      estimatedStartupSeconds: 5)
    let request = QEMULaunchRequest(
      record: record, plan: plan, layout: layout, baseImage: base, installation: installation)
    let machine = try await QEMUBackend.lift { try await QEMUMachine.launch(request) }
    let result: ProbeResult
    do {
      result = try await exercise(machine)
    } catch {
      await machine.kill()
      throw error
    }
    await machine.kill()
    return result
  }

  private func exercise(_ machine: QEMUMachine) async throws(VMLabError) -> ProbeResult {
    // The shell prompt says the firmware is idle and reading the console.
    _ = try await QEMUBackend.lift {
      try await machine.serial.wait(for: "Shell> ", since: 0, timeout: bootTimeout)
    }
    do {
      try await QMPSnapshots.save(tag: "probe", qmp: machine.qmp, timeout: jobTimeout)
      try await QMPSnapshots.load(tag: "probe", qmp: machine.qmp, timeout: jobTimeout)
    } catch {
      return .no
    }
    guard machine.isRunning, (try? await machine.status().running) == true else { return .no }
    do {
      let mark = try await machine.serial.write("echo vmlab-probe-ok\r")
      _ = try await machine.serial.wait(for: "vmlab-probe-ok", since: mark, timeout: .seconds(15))
      return .yes
    } catch {
      return .no
    }
  }

  /// Under `home/probes/`, or under /tmp when that would make socket paths too long.
  static func layout(home: URL) -> QEMULayout {
    let name = "live-snapshot-\(getpid())"
    let preferred = QEMULayout(vmDirectory: home.appending(path: "probes/\(name)"))
    if (try? preferred.validate()) != nil { return preferred }
    return QEMULayout(vmDirectory: URL(filePath: "/tmp/vmlab-probe-\(name)"))
  }
}

extension VMLabQEMU {
  /// The slow probes this module owns, for `Engines` to register.
  public static var probeRunners: [any SlowProbeRunner] {
    [QEMULiveSnapshotProbe(), QEMUVmnetProbe()]
  }
}
