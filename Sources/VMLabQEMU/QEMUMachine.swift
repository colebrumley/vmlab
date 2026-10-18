import Darwin
import Foundation
import VMLabCore

/// Everything `QEMUMachine.launch` needs.
public struct QEMULaunchRequest: Sendable {
  public var record: VMRecord
  public var plan: Plan
  public var layout: QEMULayout
  /// The pulled image's qcow2, the backing file of the guest's `disk.qcow2` overlay.
  public var baseImage: URL
  public var boot: BootSpec
  /// The cloud-init seed to build into `seed.iso`; nil attaches none.
  public var seed: CloudInitConfig?
  public var installation: QEMUInstallation
  /// Chosen when the plan grants `gdb` and this is nil.
  public var gdbPort: Int?
  /// Forwarded to the guest's port 22 when set.
  public var sshHostPort: Int?

  public init(
    record: VMRecord, plan: Plan, layout: QEMULayout, baseImage: URL,
    boot: BootSpec = BootSpec(), seed: CloudInitConfig? = nil, installation: QEMUInstallation,
    gdbPort: Int? = nil, sshHostPort: Int? = nil
  ) {
    self.record = record
    self.plan = plan
    self.layout = layout
    self.baseImage = baseImage
    self.boot = boot
    self.seed = seed
    self.installation = installation
    self.gdbPort = gdbPort
    self.sshHostPort = sshHostPort
  }
}

/// One running QEMU guest: its daemonized process, the QMP client and the serial channel.
/// `launch` prepares the disk overlay, EFI variables and seed, starts QEMU halted (`-S`), connects
/// QMP and the serial socket, and only then sends `cont`, so `serial.log` holds the first byte.
/// `attach` reconnects to a guest that is already running (a restarted server).
public actor QEMUMachine {
  public nonisolated let layout: QEMULayout
  public nonisolated let pid: Int32
  public nonisolated let qmp: QMPClient
  public nonisolated let serial: SerialChannel
  public nonisolated let runtime: VMRuntime

  init(layout: QEMULayout, pid: Int32, qmp: QMPClient, serial: SerialChannel, runtime: VMRuntime) {
    self.layout = layout
    self.pid = pid
    self.qmp = qmp
    self.serial = serial
    self.runtime = runtime
  }

  // MARK: Starting

  /// The qcow2 of a pulled image, or `image_not_found`.
  public static func baseImage(named name: String, in store: ImageStore) throws(VMLabError) -> URL {
    guard let pulled = store.pulled(name), let file = pulled.files[ImageFormat.qcow2.rawValue]
    else {
      throw VMLabError(
        code: .imageNotFound, message: "The image \(name) is not pulled as qcow2.",
        hint: "Run `vmlab images pull \(name)`.",
        data: [
          "name": .string(name),
          "available": .array(store.list().filter { $0.pulled != nil }.map { .string($0.name) }),
        ])
    }
    return store.imageDirectory(name).appending(path: file)
  }

  /// Creates `disk.qcow2` over `baseImage` (sized to the plan's disk), copies the EFI variable
  /// template and builds `seed.iso`. Existing disk and variables are kept, so a restart boots the
  /// same guest; the seed is rebuilt every time.
  public static func prepare(_ request: QEMULaunchRequest) throws(VMLabError) {
    let layout = request.layout
    let files = FileManager.default
    do {
      try files.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    } catch {
      throw ioError("create \(layout.directory.path)", error)
    }
    if !files.fileExists(atPath: layout.disk.path) {
      let diskGB =
        ResourceLimits.resolve(request.plan.resources, for: request.plan.guest.os).diskGB ?? 32
      try run(
        request.installation.qemuImg,
        [
          "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", request.baseImage.path,
          layout.disk.path, "\(diskGB)G",
        ], step: "qemu-img create")
    }
    if request.boot.mode != .kernel, !files.fileExists(atPath: layout.efiVars.path) {
      let firmware = try request.installation.firmware(for: request.plan.guest.arch)
      do {
        try files.copyItem(atPath: firmware.varsTemplate, toPath: layout.efiVars.path)
      } catch {
        throw ioError("copy the EFI variable template", error)
      }
    }
    if let seed = request.seed {
      do {
        try CloudInit.makeSeed(seed, directory: layout.seedSource, iso: layout.seed)
      } catch let error as VMLabError {
        throw error
      } catch {
        throw ioError("build seed.iso", error)
      }
    }
  }

  /// Prepares the guest's files, starts QEMU and returns the connected machine. The CPU runs
  /// unless `boot.haltAtStart` is set, in which case it waits for `cont` (R-703).
  public static func launch(
    _ request: QEMULaunchRequest, connectTimeout: Duration = .seconds(10)
  ) async throws -> QEMUMachine {
    let layout = request.layout
    try layout.validate()
    if let pid = readPID(layout), isAlive(pid) {
      throw VMLabError(
        code: .wrongState, message: "A QEMU process (pid \(pid)) already runs this VM.",
        hint: "Stop the VM first, or reconnect to it.",
        data: ["state": .string(VMState.running.rawValue), "pid": .number(Double(pid))])
    }
    try prepare(request)
    var options = QEMULaunchOptions(
      boot: request.boot, seed: request.seed != nil, gdbPort: request.gdbPort,
      sshHostPort: request.sshHostPort)
    if request.boot.mode != .kernel {
      options.firmware = try request.installation.firmware(for: request.plan.guest.arch)
    }
    if request.plan.grants(.gdb), options.gdbPort == nil {
      options.gdbPort = try freeLoopbackPort()
    }
    let arguments = try QEMUCommandLine.arguments(
      record: request.record, plan: request.plan, layout: layout, options: options)
    for stale in layout.sockets + [layout.pidFile] {
      try? FileManager.default.removeItem(at: stale)
    }
    let binary = request.installation.systemBinary(for: request.plan.guest.arch)
    try await daemonize(binary, arguments, log: layout.log)
    guard let pid = readPID(layout) else {
      throw VMLabError(
        code: .engineError, message: "QEMU started but wrote no pid file.",
        hint: "See qemu.log in the VM directory.",
        data: ["engine": .string("qemu"), "raw": .string(tail(of: layout.log))])
    }
    let machine: QEMUMachine
    do {
      machine = try await connect(
        layout: layout, pid: pid, gdbPort: options.gdbPort, sshPort: request.sshHostPort,
        timeout: connectTimeout)
    } catch {
      Darwin.kill(pid, SIGKILL)
      throw error
    }
    if !request.boot.haltAtStart {
      do { try await machine.cont() } catch {
        await machine.kill()
        throw error
      }
    }
    return machine
  }

  /// Reconnects to the QEMU process already running in `layout` (its pid file, QMP and serial
  /// sockets). `guest_unreachable` when no live process owns the directory.
  public static func attach(
    layout: QEMULayout, gdbPort: Int? = nil, sshPort: Int? = nil,
    connectTimeout: Duration = .seconds(5)
  ) async throws -> QEMUMachine {
    guard let pid = readPID(layout), isAlive(pid) else {
      throw VMLabError(
        code: .guestUnreachable, message: "No QEMU process runs in \(layout.directory.path).",
        hint: "Start the VM.", data: ["tried": .string(layout.pidFile.path)])
    }
    return try await connect(
      layout: layout, pid: pid, gdbPort: gdbPort, sshPort: sshPort, timeout: connectTimeout)
  }

  private static func connect(
    layout: QEMULayout, pid: Int32, gdbPort: Int?, sshPort: Int?, timeout: Duration
  ) async throws -> QEMUMachine {
    let qmp = try await QMPClient.connect(
      socketPath: layout.qmpSocket.path, connectTimeout: timeout)
    let serial = SerialChannel(socketPath: layout.serialSocket.path, logURL: layout.serialLog)
    do {
      try await serial.start(connectTimeout: timeout)
    } catch {
      await qmp.close()
      throw error
    }
    let runtime = VMRuntime(
      pid: pid, controlSocket: layout.qmpSocket.path, qmpSocket: layout.qmpSocket.path,
      serialSocket: layout.serialSocket.path, vncSocket: layout.vncSocket.path,
      gdbEndpoint: gdbPort.map { "tcp:127.0.0.1:\($0)" }, sshPort: sshPort)
    return QEMUMachine(layout: layout, pid: pid, qmp: qmp, serial: serial, runtime: runtime)
  }

  // MARK: Control

  /// Releases the CPU of a guest started halted.
  public func cont() async throws { try await qmp.execute("cont") }

  public func status() async throws -> QMPStatus { try await qmp.queryStatus() }

  /// Whether the QEMU process still exists.
  public nonisolated var isRunning: Bool { Self.isAlive(pid) }

  /// Sends `system_powerdown` (ACPI power button) and waits for the process to exit. Throws
  /// `timeout` when the guest has not shut down within `timeout`; the process is left running so
  /// the caller can decide to kill it (Appendix G: 60 s grace).
  public func powerdown(timeout: Duration = .seconds(60)) async throws {
    try await qmp.execute("system_powerdown")
    guard await waitForExit(timeout: timeout) else {
      throw VMLabError(
        code: .timeout, message: "The guest did not shut down after the power button.",
        hint: "Kill the VM, or give the guest longer.",
        data: ["timeoutSeconds": .number(QMPClient.seconds(timeout))])
    }
    await disconnect()
  }

  /// Ends QEMU at once: QMP `quit`, then `SIGKILL` if the process is still there after a second.
  public func kill() async {
    if await qmp.isConnected {
      _ = try? await qmp.execute("quit", timeout: .seconds(2))
    }
    if !(await waitForExit(timeout: .seconds(1))) {
      Darwin.kill(pid, SIGKILL)
      _ = await waitForExit(timeout: .seconds(5))
    }
    await disconnect()
  }

  /// Polls until the process is gone; false at `timeout`.
  public func waitForExit(timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while Self.isAlive(pid) {
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return true
  }

  /// Closes the QMP connection and the serial channel without touching the process.
  public func disconnect() async {
    await qmp.close()
    await serial.stop()
  }

  // MARK: Host plumbing

  /// A free TCP port on 127.0.0.1, from the kernel's ephemeral range.
  public static func freeLoopbackPort() throws(VMLabError) -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ioError("open a socket", POSIXError(.init(rawValue: errno)!)) }
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
      }
    }
    guard ok else { throw ioError("bind a loopback port", POSIXError(.init(rawValue: errno)!)) }
    return Int(UInt16(bigEndian: addr.sin_port))
  }

  static func readPID(_ layout: QEMULayout) -> Int32? {
    guard let text = try? String(contentsOf: layout.pidFile, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func isAlive(_ pid: Int32) -> Bool {
    pid > 0 && (Darwin.kill(pid, 0) == 0 || errno == EPERM)
  }

  /// Runs QEMU, whose foreground parent exits once the daemon is initialised (or has failed).
  /// Its output goes to `log`.
  static func daemonize(_ binary: URL, _ arguments: [String], log: URL) async throws {
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw QEMUInstallation.missingTool(binary.lastPathComponent, path: binary.path)
    }
    if !FileManager.default.fileExists(atPath: log.path) {
      FileManager.default.createFile(atPath: log.path, contents: nil)
    }
    let handle: FileHandle
    do {
      handle = try FileHandle(forWritingTo: log)
      try handle.seekToEnd()
    } catch {
      throw ioError("open \(log.path)", error)
    }
    defer { try? handle.close() }
    handle.write(Data("vmlab: \(binary.path) \(arguments.joined(separator: " "))\n".utf8))
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.environment = daemonEnvironment()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: ioError("run \(binary.path)", error))
      }
    }
    guard status == 0 else {
      throw VMLabError(
        code: .engineError, message: "QEMU exited with status \(status) while starting.",
        hint: "See data.raw (the end of qemu.log).",
        data: [
          "engine": .string("qemu"), "raw": .string(tail(of: log)),
          "status": .number(Double(status)),
        ])
    }
  }

  /// This process's environment plus `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`. `-daemonize`
  /// forks without exec, and macOS aborts a forked child that initialises an Objective-C class
  /// ("crashed on child side of fork pre-exec"); QEMU 11.1 under HVF does exactly that on its
  /// first `snapshot-save`, so without this every live checkpoint killed the guest (R-307).
  static func daemonEnvironment(
    _ base: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = base
    environment["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] = "YES"
    return environment
  }

  static func run(_ tool: URL, _ arguments: [String], step: String) throws(VMLabError) {
    guard FileManager.default.isExecutableFile(atPath: tool.path) else {
      throw QEMUInstallation.missingTool(tool.lastPathComponent, path: tool.path)
    }
    guard let result = ProcessRunner().run(tool.path, arguments) else {
      throw QEMUInstallation.missingTool(tool.lastPathComponent, path: tool.path)
    }
    guard result.status == 0 else {
      throw VMLabError(
        code: .engineError, message: "\(step) failed with status \(result.status).",
        hint: "See data.raw for the tool's message.",
        data: ["engine": .string("qemu"), "raw": .string(result.output), "step": .string(step)])
    }
  }

  static func tail(of url: URL, bytes: Int = 4096) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    return String(decoding: data.suffix(bytes), as: UTF8.self)
  }

  static func ioError(_ what: String, _ error: any Error) -> VMLabError {
    VMLabError(
      code: .internal, message: "Could not \(what): \(error.localizedDescription)",
      hint: "Check the permissions and free space of VMLAB_HOME.",
      data: ["error": .string("\(error)")])
  }
}
