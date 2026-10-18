import Darwin
import Foundation
import VMLabCore

/// The slow probe `qemu_vmnet` (R-309, Appendix E): starts a throwaway HVF guest (edk2, an empty
/// disk, no image) whose only NIC is `-netdev vmnet-shared`. Creating the vmnet interface is the
/// step that needs root or Apple's `com.apple.vm.networking` entitlement, and QEMU fails at start
/// when it is refused: `no` then, `yes` when the guest runs. Throws when the guest could not start
/// for another reason. (The guest is not booted far enough to take a DHCP lease; on a host where
/// the interface can be created, vmnet's DHCP server is part of the same framework.)
public struct QEMUVmnetProbe: SlowProbeRunner {
  public var probe: SlowProbe { .qemuVmnet }
  public var installation: QEMUInstallation?

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
      rmdir(layout.directory.deletingLastPathComponent().path)
    }
    do {
      try files.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    } catch {
      throw QEMUMachine.ioError("create \(layout.directory.path)", error)
    }
    let base = layout.directory.appending(path: "base.qcow2")
    try QEMUMachine.run(
      installation.qemuImg, ["create", "-q", "-f", "qcow2", base.path, "64M"],
      step: "qemu-img create")
    let request = Self.request(layout: layout, base: base, installation: installation)
    let machine: QEMUMachine
    do {
      machine = try await QEMUBackend.lift { try await QEMUMachine.launch(request) }
    } catch {
      if Self.isVmnetRefusal(error) { return .no }
      throw error
    }
    let running = machine.isRunning
    await machine.kill()
    return running ? .yes : .no
  }

  /// The probe guest: one CPU, 1 GB, serial only, the vmnet NIC.
  static func request(
    layout: QEMULayout, base: URL, installation: QEMUInstallation
  ) -> QEMULaunchRequest {
    let guest = GuestSpec(os: .linux, arch: .arm64)
    let resources = ResourceSpec(cpus: 1, memoryGB: 1, diskGB: 1)
    let record = VMRecord(
      id: "probe-vmnet", profile: .qemuHVF, guest: guest, features: [.serial, .netFast],
      resources: resources, network: NetworkSpec(mode: .nat))
    let plan = Plan(
      profile: .qemuHVF, guest: guest, resources: resources, features: [.serial, .netFast],
      estimatedStartupSeconds: 5)
    return QEMULaunchRequest(
      record: record, plan: plan, layout: layout, baseImage: base, installation: installation,
      vmnet: true)
  }

  /// Whether a failed start is QEMU refusing the vmnet interface (no privilege), as opposed to
  /// any other failure: one of QEMU's own lines (not the `vmlab:` launch line `daemonize` echoes
  /// into qemu.log, which names `vmnet-shared` on every probe) says it cannot create it.
  static func isVmnetRefusal(_ error: VMLabError) -> Bool {
    guard error.code == .engineError, case .string(let raw)? = error.data["raw"] else {
      return false
    }
    return raw.split(whereSeparator: \.isNewline).contains { line in
      !line.hasPrefix("vmlab: ") && line.localizedCaseInsensitiveContains("vmnet")
        && (line.localizedCaseInsensitiveContains("cannot")
          || line.localizedCaseInsensitiveContains("failure")
          || line.localizedCaseInsensitiveContains("privilege")
          || line.localizedCaseInsensitiveContains("permission"))
    }
  }

  /// Under `home/probes/`, or under /tmp when that would make socket paths too long.
  static func layout(home: URL) -> QEMULayout {
    let name = "vmnet-\(getpid())"
    let preferred = QEMULayout(vmDirectory: home.appending(path: "probes/\(name)"))
    if (try? preferred.validate()) != nil { return preferred }
    return QEMULayout(vmDirectory: URL(filePath: "/tmp/vmlab-probe-\(name)"))
  }
}
