import Foundation
import VMLabCore

extension VZRunnerConfig {
  /// The macOS machine for `record` from its Tart clone: the record's resources (Appendix G macOS
  /// defaults, never below the image's `cpuCountMin`/`memorySizeMin`), `VZMacOSBootLoader` on a
  /// Mac platform from `config.json` and `nvram.bin`, `disk.img`, one NAT NIC with the clone's
  /// MAC (so Tart's own lease lookup agrees) unless the network is `none`, no console (VZ gives
  /// macOS guests none), the balloon, and always a Mac display: Screen Sharing needs one.
  public static func macOS(
    record: VMRecord, clone: TartVMFiles, config: TartVMConfig
  ) -> VZRunnerConfig {
    let resources = ResourceLimits.resolve(record.resources, for: .macos)
    let cpus = max(resources.cpus ?? 4, config.cpuCountMin)
    let memory = max(UInt64(resources.memoryGB ?? 8) << 30, config.memorySizeMin)
    return VZRunnerConfig(
      cpus: cpus,
      memoryBytes: memory,
      boot: .macOS(
        hardwareModel: config.hardwareModel ?? "", machineIdentifier: config.ecid ?? "",
        auxiliaryStorage: clone.nvram.path),
      disks: [Disk(path: clone.disk.path)],
      network: record.network.mode == .disabled
        ? [] : [.nat(macAddress: MACAddress.normalize(config.macAddress) ?? config.macAddress)],
      consoleLog: nil,
      memoryBalloon: true,
      graphics: Graphics(
        width: config.display?.width ?? 1024, height: config.display?.height ?? 768,
        pixelsPerInch: 72))
  }
}

/// The `vz-macos` backend: create `tart clone`s the pulled image (an APFS clone, seconds) and
/// records the clone's directory in `vm.json`; start runs the clone's files in our own `vmlab-vz`
/// runner (`VZRunnerConfig.macOS`), so pause, stop and the control socket are the same as
/// `vz-linux`; the first start provisions the guest over SSH (R-606, `MacProvisioner`); destroy
/// `tart delete`s the clone.
public struct VZMacBackend: Backend {
  public let profile: Profile = .vzMacOS
  public let store: Store
  public let launcher: VZRunnerLauncher
  public var stopTimeout: Duration
  /// How long `start` waits for the guest's DHCP lease before recording no `runtime.ip`.
  public var leaseTimeout: Duration
  public var leasePath: String
  /// Finds `tart`; only create and destroy need it.
  public var tart: @Sendable () throws(VMLabError) -> Tart
  /// How long first-boot provisioning waits for sshd (Appendix G: 300 s for macOS).
  public var bootTimeout: Duration
  /// Runs `ssh-keygen`.
  public var commands: any CommandRunning

  public init(
    store: Store, launcher: VZRunnerLauncher = VZRunnerLauncher(),
    stopTimeout: Duration = .seconds(120), leaseTimeout: Duration = .seconds(180),
    leasePath: String = DHCPLeases.defaultPath,
    tart: @escaping @Sendable () throws(VMLabError) -> Tart = { () throws(VMLabError) in
      try Tart.locate()
    },
    bootTimeout: Duration = .seconds(300), commands: any CommandRunning = ProcessRunner()
  ) {
    self.bootTimeout = bootTimeout
    self.commands = commands
    self.store = store
    self.launcher = launcher
    self.stopTimeout = stopTimeout
    self.leaseTimeout = leaseTimeout
    self.leasePath = leasePath
    self.tart = tart
  }

  /// The runner plumbing shared with `vz-linux` (stop, kill, pause, resume, exit).
  var runner: VZBackend {
    VZBackend(
      store: store, launcher: launcher, stopTimeout: stopTimeout, leaseTimeout: leaseTimeout,
      leasePath: leasePath)
  }

  /// The Tart name of `record`'s clone: the recorded directory's name, else the VM id.
  static func cloneName(_ record: VMRecord) -> String {
    record.tartClone.map { URL(filePath: $0).lastPathComponent } ?? record.id
  }

  public func create(_ record: VMRecord, plan: Plan) async throws(VMLabError) {
    guard let name = record.image else {
      throw VMLabError.invalidRequest(
        field: "image", reason: "a macOS guest needs a Tart image",
        hint: "Use image macos-base.")
    }
    let images = ImageStore(home: store.home)
    guard let pulled = images.pulled(name), pulled.format == .tart else {
      throw VMLabError(
        code: .imageNotFound, message: "Image \(name) is not a pulled Tart image",
        hint: "Run vmlab images pull macos-base.", data: ["image": .string(name)])
    }
    let tart = try tart()
    let clone = try tart.clone(pulled.tartVM ?? pulled.source, to: record.id)
    do throws(VMLabError) {
      _ = try TartVMConfig.read(from: clone.directory)
      for file in [clone.disk, clone.nvram]
      where !FileManager.default.fileExists(atPath: file.path) {
        throw TartVMConfig.layoutError(file, "missing from the clone")
      }
      try store.update(id: record.id) { $0.tartClone = clone.directory.path }
      let dir = store.directory(of: record.id)
      // VMManager makes the key first (R-400); this keeps a direct create complete.
      try SSHKeys.generate(in: dir, comment: "vmlab-\(record.id)", runner: commands)
      if Self.wantsScreenSharing(record) { _ = try MacProvisioner.ensureVNCPassword(in: dir) }
    } catch {
      try? tart.delete(record.id)
      throw error
    }
  }

  /// Launches the runner on the clone's files, then waits up to `leaseTimeout` for the lease of
  /// the clone's MAC and records it as `runtime.ip`.
  public func start(_ record: VMRecord) async throws(VMLabError) -> VMRuntime {
    guard let path = record.tartClone else {
      throw VMLabError(
        code: .engineError, message: "VM \(record.id) has no Tart clone recorded",
        hint: "Destroy it and create it again.",
        data: ["engine": .string("tart"), "vm": .string(record.id)])
    }
    let clone = TartVMFiles(directory: URL(filePath: path))
    let tartConfig = try TartVMConfig.read(from: clone.directory)
    let config = VZRunnerConfig.macOS(record: record, clone: clone, config: tartConfig)
    let handle = try await launcher.launch(
      vmDirectory: store.directory(of: record.id), config: config)
    var runtime = handle.runtime
    if case .nat(let mac?) = config.network.first {
      runtime.ip = await DHCPLeases.waitForIP(mac: mac, path: leasePath, timeout: leaseTimeout)
    }
    let dir = store.directory(of: record.id)
    if !MacProvisioner.isProvisioned(dir) {
      do throws(VMLabError) {
        try await provision(record, ip: runtime.ip)
      } catch {
        var running = record
        running.runtime = runtime
        try? await runner.kill(running)
        throw error
      }
    }
    return runtime
  }

  /// Whether provisioning sets the legacy VNC password: the plan requested a display feature,
  /// the same test `DisplayEndpoint.forVM` uses to offer Screen Sharing (R-503).
  static func wantsScreenSharing(_ record: VMRecord) -> Bool {
    DisplayEndpoint.isProvisioned(record)
  }

  /// R-606: the first boot's SSH provisioning (`MacProvisioner`).
  func provision(_ record: VMRecord, ip: String?) async throws(VMLabError) {
    let dir = store.directory(of: record.id)
    guard let ip else {
      throw VMLabError(
        code: .provisionFailed,
        message:
          "The macOS guest leased no address within \(leaseTimeout), so it cannot be provisioned",
        hint: "Check vmnet (/var/db/dhcpd_leases) and <vm>/vz.log, then start again.",
        data: ["step": .string("lease"), "log": .string(dir.appending(path: "vz.log").path)])
    }
    let login =
      record.image.flatMap { ImageStore(home: store.home).pulled($0)?.login }
      ?? ImageLogin(user: "admin", password: "admin")
    let key: String
    do {
      key = try String(contentsOf: dir.appending(path: "id_ed25519.pub"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      throw VMLabError(
        code: .provisionFailed, message: "The VM's SSH public key cannot be read: \(error)",
        hint: "Destroy the VM and create it again.",
        data: ["step": .string("authorized_keys"), "log": .string(dir.path)])
    }
    var provisioner = MacProvisioner(
      vmDirectory: dir, login: login, hostname: VZBackend.hostname(for: record), publicKey: key,
      vncPassword: Self.wantsScreenSharing(record)
        ? try MacProvisioner.ensureVNCPassword(in: dir) : nil)
    provisioner.sshTimeout = bootTimeout
    try await provisioner.provision(ip: ip)
  }

  public func stop(_ record: VMRecord) async throws(VMLabError) { try await runner.stop(record) }
  public func stop(_ record: VMRecord, grace: Duration?) async throws(VMLabError) {
    try await runner.stop(record, grace: grace)
  }
  public func kill(_ record: VMRecord) async throws(VMLabError) { try await runner.kill(record) }
  public func pause(_ record: VMRecord) async throws(VMLabError) { try await runner.pause(record) }
  public func resume(_ record: VMRecord) async throws(VMLabError) {
    try await runner.resume(record)
  }

  /// Ends a runner that is still there, then deletes the Tart clone.
  public func destroy(_ record: VMRecord) async throws(VMLabError) {
    try await runner.destroy(record)
    let tart = try tart()
    let name = Self.cloneName(record)
    try tart.delete(name)
    // A clone recorded under another TART_HOME than this process sees.
    if let path = record.tartClone, FileManager.default.fileExists(atPath: path),
      URL(filePath: path).standardizedFileURL != tart.files(of: name).directory.standardizedFileURL
    {
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  public func attach(_ record: VMRecord) async throws(VMLabError) -> any RunningVM {
    let handle = try await VMLabVZ.attach(socketPath: runner.target(record).client.socketPath)
    let ssh = SSHEndpoint(runtime: record.runtime).map {
      SSHTarget(record: record, endpoint: $0, store: store)
    }
    return VZRunningVM(
      id: record.id, profile: profile, features: record.features, handle: handle, ssh: ssh)
  }
}
