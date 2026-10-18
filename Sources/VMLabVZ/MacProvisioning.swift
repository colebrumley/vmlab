import Foundation
import VMLabCore

/// First boot of a `vz-macos` guest (R-606), over SSH with the image's password: install the VM's
/// public key, set the hostname, and when `gui` was granted turn on Screen Sharing with the legacy
/// VNC password from `<vm>/vnc.pass`, sending VNC viewers straight to the console session
/// (`VNCAlwaysStartOnConsole`; otherwise macOS 26 shows a password-only viewer a lock screen of its
/// own), and check that port 5900 answers RFB. Every step is logged
/// to `<vm>/provision.log`; success writes `<vm>/provisioned`, so later starts skip it. Password
/// authentication stays on (the images are disposable).
public struct MacProvisioner: Sendable {
  public var vmDirectory: URL
  public var login: ImageLogin
  public var hostname: String
  public var publicKey: String
  /// The legacy VNC password to set, or nil when `gui` was not granted.
  public var vncPassword: String?
  /// How long to wait for the guest's sshd to accept the password.
  public var sshTimeout: Duration
  /// Overridable for tests.
  public var ssh: @Sendable (PasswordSSH, String, Data) async -> CommandOutput?
  public var rfbProbe: @Sendable (String, Int, Duration) async -> Bool

  public init(
    vmDirectory: URL, login: ImageLogin, hostname: String, publicKey: String,
    vncPassword: String?, sshTimeout: Duration = .seconds(300),
    ssh: @escaping @Sendable (PasswordSSH, String, Data) async -> CommandOutput? = {
      await $0.run($1, input: $2, timeout: .seconds(60))
    },
    rfbProbe: @escaping @Sendable (String, Int, Duration) async -> Bool = MacProvisioner.rfbAnswers
  ) {
    self.vmDirectory = vmDirectory
    self.login = login
    self.hostname = hostname
    self.publicKey = publicKey
    self.vncPassword = vncPassword
    self.sshTimeout = sshTimeout
    self.ssh = ssh
    self.rfbProbe = rfbProbe
  }

  public static func marker(in vmDirectory: URL) -> URL {
    vmDirectory.appending(path: "provisioned")
  }

  public static func isProvisioned(_ vmDirectory: URL) -> Bool {
    FileManager.default.fileExists(atPath: marker(in: vmDirectory).path)
  }

  public var log: URL { vmDirectory.appending(path: "provision.log") }

  static let kickstart =
    "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

  /// The steps, in order: a name, the remote command and its stdin. The hostname and VNC password
  /// are vmlab's own (a DNS label, `[A-Za-z0-9]{8}`), so they are safe inside the commands.
  public func steps() -> [(name: String, command: String, input: Data)] {
    let sudoInput = Data("\(login.password ?? "")\n".utf8)
    var steps: [(String, String, Data)] = [
      (
        "authorized_keys",
        "umask 077 && mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys",
        Data("\(publicKey)\n".utf8)
      ),
      (
        "hostname",
        "sudo -S -p '' /bin/sh -c 'scutil --set HostName \(hostname) && "
          + "scutil --set LocalHostName \(hostname) && scutil --set ComputerName \(hostname)'",
        sudoInput
      ),
    ]
    if let vncPassword {
      steps.append(
        (
          "screen_sharing",
          "sudo -S -p '' /bin/sh -c '\(Self.kickstart) -configure -clientopts -setvnclegacy "
            + "-vnclegacy yes -setvncpw -vncpw \(vncPassword) && "
            + "defaults write /Library/Preferences/com.apple.RemoteManagement.plist "
            + "VNCAlwaysStartOnConsole -bool true && "
            + "launchctl enable system/com.apple.screensharing && "
            + "(launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist"
            + " 2>/dev/null; true) && launchctl kickstart -k system/com.apple.screensharing'",
          sudoInput
        ))
    }
    return steps
  }

  /// Runs the steps against the guest at `ip`; `provision_failed` names the step that failed.
  public func provision(ip: String) async throws(VMLabError) {
    try? FileManager.default.removeItem(at: Self.marker(in: vmDirectory))
    let session = PasswordSSH(
      user: login.user, host: ip, password: login.password ?? "", scratch: vmDirectory)
    append("provisioning \(login.user)@\(ip)")

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: sshTimeout)
    var last: CommandOutput? = nil
    while true {
      last = await ssh(session, "true", Data())
      if last?.status == 0 { break }
      if clock.now >= deadline {
        throw failure("ssh", "sshd did not accept the image password within \(sshTimeout)", last)
      }
      try? await Task.sleep(for: .seconds(3))
    }
    append("ssh: password login works")

    for step in steps() {
      let output = await ssh(session, step.command, step.input)
      append("\(step.name): exit \(output.map { String($0.status) } ?? "none")")
      if let text = output?.output, !text.isEmpty { append(text) }
      guard output?.status == 0 else { throw failure(step.name, "the step failed", output) }
    }

    if vncPassword != nil {
      guard await rfbProbe(ip, 5900, .seconds(60)) else {
        throw failure("screen_sharing", "port 5900 did not answer RFB", nil)
      }
      append("screen_sharing: RFB answers on \(ip):5900")
    }
    try? FileManager.default.removeItem(at: session.askpass)
    do {
      try Data("\(ISO8601DateFormatter().string(from: Date()))\n".utf8).write(
        to: Self.marker(in: vmDirectory))
    } catch {
      throw failure("marker", "cannot write \(Self.marker(in: vmDirectory).path)", nil)
    }
    append("provisioned")
  }

  func failure(_ step: String, _ reason: String, _ output: CommandOutput?) -> VMLabError {
    append("\(step) failed: \(reason)")
    return VMLabError(
      code: .provisionFailed, message: "Provisioning the macOS guest failed at \(step): \(reason)",
      hint: "See <vm>/provision.log; destroy the VM and create it again.",
      data: [
        "step": .string(step), "log": .string(log.path),
        "output": .string(output?.output ?? ""),
      ])
  }

  func append(_ line: String) {
    let text = line.hasSuffix("\n") ? line : line + "\n"
    let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = text.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
  }

  /// A random legacy VNC password: eight letters and digits (VNC Authentication keeps eight).
  public static func makeVNCPassword() -> String {
    let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    var rng = SystemRandomNumberGenerator()
    return String((0..<8).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
  }

  /// `<vm>/vnc.pass`, created (mode 0600) with a fresh password when absent.
  public static func ensureVNCPassword(in vmDirectory: URL) throws(VMLabError) -> String {
    let file = vmDirectory.appending(path: "vnc.pass")
    if let text = try? String(contentsOf: file, encoding: .utf8) {
      let password = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !password.isEmpty { return password }
    }
    let password = makeVNCPassword()
    do {
      try Data(password.utf8).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot write \(file.path): \(error)",
        hint: "Check that the VM directory is writable.")
    }
    return password
  }

  /// True once a TCP connection to `host:port` reads an `RFB ` version banner, retried until
  /// `within` runs out.
  @Sendable public static func rfbAnswers(host: String, port: Int, within: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: within)
    while clock.now < deadline {
      let banner = await HostCommand.run(
        "/usr/bin/nc", ["-w", "3", host, String(port)], timeout: .seconds(5))
      if banner?.output.hasPrefix("RFB ") == true { return true }
      try? await Task.sleep(for: .seconds(2))
    }
    return false
  }
}
