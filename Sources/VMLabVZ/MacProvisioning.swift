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
  /// The segment NIC to give its static address (R-901), or nil off any segment.
  public var segment: SegmentAttachment?

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
    if let segment {
      // The script goes to a file first (stdin carries the sudo password in the next step).
      steps.append(
        (
          "segment_script", "umask 022 && cat > /tmp/vmlab-segment.sh",
          Data(Self.segmentScript.utf8)
        ))
      steps.append(
        (
          "segment_address",
          "sudo -S -p '' /bin/sh /tmp/vmlab-segment.sh \(segment.mac) \(segment.address) "
            + Self.netmask(segment.prefixLength),
          sudoInput
        ))
    }
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

  /// Sets a static IPv4 address on the network service of the interface with MAC `$1`: the
  /// interface by `ifconfig`, its service by `networksetup -listnetworkserviceorder` (made with
  /// `-createnetworkservice` when macOS has none for it yet), then `networksetup -setmanual`.
  /// The MAC, address and mask are vmlab's own values (hex, dotted quads).
  static let segmentScript = #"""
    #!/bin/sh
    set -e
    mac="$1"; ip="$2"; mask="$3"
    dev=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
      dev=$(ifconfig -a | awk -v m="$mac" '/^[a-z]/ {d=$1; sub(":$", "", d)} $1 == "ether" && tolower($2) == m {print d}')
      [ -n "$dev" ] && break
      sleep 2
    done
    [ -n "$dev" ] || { echo "no interface has MAC $mac" >&2; exit 3; }
    service() {
      networksetup -listnetworkserviceorder | awk -v d="$dev" '/^\([0-9*]+\) / {s=$0; sub(/^\([0-9*]+\) /, "", s)} index($0, "Device: " d ")") {print s}'
    }
    svc=$(service)
    if [ -z "$svc" ]; then
      networksetup -detectnewhardware || true
      svc=$(service)
    fi
    if [ -z "$svc" ]; then
      svc="vmlab segment"
      networksetup -createnetworkservice "$svc" "$dev"
    fi
    networksetup -setmanual "$svc" "$ip" "$mask"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      ifconfig "$dev" | grep -q "inet $ip " && exit 0
      sleep 1
    done
    echo "$dev ($svc) did not take $ip" >&2
    exit 4
    """#

  /// `24` → `255.255.255.0`.
  static func netmask(_ prefix: Int) -> String {
    let bits = UInt32.max << UInt32(32 - max(0, min(32, prefix)))
    return (0..<4).map { String((bits >> UInt32(24 - 8 * $0)) & 0xff) }.joined(separator: ".")
  }

  /// The name of the first step: waiting for sshd to take the image password.
  public static let sshStep = "ssh"

  /// `command` as `provision.json` records it: the VNC password replaced by where it is kept.
  func recorded(_ command: String) -> String {
    guard let vncPassword else { return command }
    return command.replacingOccurrences(of: vncPassword, with: "<vnc.pass>")
  }

  /// Runs the steps against the guest at `ip`; `provision_failed` names the step that failed.
  /// Either way the steps land in `<vm>/provision.json` (R-1004: `ssh`, `authorized_keys`,
  /// `hostname`, `screen_sharing`), so `vm_inspect` shows a failed first boot.
  public func provision(ip: String) async throws(VMLabError) {
    try? FileManager.default.removeItem(at: Self.marker(in: vmDirectory))
    try? FileManager.default.removeItem(at: ProvisionReport.url(in: vmDirectory))
    let session = PasswordSSH(
      user: login.user, host: ip, password: login.password ?? "", scratch: vmDirectory)
    append("provisioning \(login.user)@\(ip)")
    let planned = [(name: Self.sshStep, command: "true", input: Data())] + steps()
    var done: [ProvisionStep] = []

    /// Records `name` as failed and the steps after it as skipped, writes the report, and
    /// returns the error to throw.
    func fail(_ name: String, _ reason: String, _ output: CommandOutput?, ms: Int?)
      -> VMLabError
    {
      let command = planned.first { $0.name == name }.map { recorded($0.command) } ?? name
      done.append(
        ProvisionStep(
          name: name, command: command, status: .failed, exitCode: output.map { Int($0.status) },
          durationMs: ms, error: output == nil ? reason : nil))
      for step in planned where !done.contains(where: { $0.name == step.name }) {
        done.append(
          ProvisionStep(name: step.name, command: recorded(step.command), status: .skipped))
      }
      writeReport(done)
      return failure(name, reason, output)
    }

    let clock = ContinuousClock()
    let begun = clock.now
    let deadline = begun.advanced(by: sshTimeout)
    var last: CommandOutput? = nil
    while true {
      last = await ssh(session, "true", Data())
      if last?.status == 0 { break }
      if clock.now >= deadline {
        throw fail(
          Self.sshStep, "sshd did not accept the image password within \(sshTimeout)", last,
          ms: Self.ms(clock.now - begun))
      }
      try? await Task.sleep(for: .seconds(3))
    }
    done.append(
      ProvisionStep(
        name: Self.sshStep, command: "true", status: .succeeded, exitCode: 0,
        durationMs: Self.ms(clock.now - begun)))
    append("ssh: password login works")

    for step in planned.dropFirst() {
      let started = clock.now
      let output = await ssh(session, step.command, step.input)
      let ms = Self.ms(clock.now - started)
      append("\(step.name): exit \(output.map { String($0.status) } ?? "none")")
      if let text = output?.output, !text.isEmpty { append(text) }
      guard output?.status == 0 else { throw fail(step.name, "the step failed", output, ms: ms) }
      if step.name == "screen_sharing" {
        guard await rfbProbe(ip, 5900, .seconds(60)) else {
          done.append(
            ProvisionStep(
              name: step.name, command: recorded(step.command), status: .failed, exitCode: 0,
              durationMs: Self.ms(clock.now - started),
              error: "port 5900 did not answer RFB"))
          writeReport(done)
          throw failure("screen_sharing", "port 5900 did not answer RFB", nil)
        }
        append("screen_sharing: RFB answers on \(ip):5900")
      }
      done.append(
        ProvisionStep(
          name: step.name, command: recorded(step.command), status: .succeeded, exitCode: 0,
          durationMs: Self.ms(clock.now - started)))
    }
    try? FileManager.default.removeItem(at: session.askpass)
    writeReport(done)
    do {
      try Data("\(ISO8601DateFormatter().string(from: Date()))\n".utf8).write(
        to: Self.marker(in: vmDirectory))
    } catch {
      throw failure("marker", "cannot write \(Self.marker(in: vmDirectory).path)", nil)
    }
    append("provisioned")
  }

  static func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }

  /// `<vm>/provision.json` with `steps`; a write failure is logged, not thrown.
  func writeReport(_ steps: [ProvisionStep]) {
    do {
      try ProvisionReport(vm: vmDirectory.lastPathComponent, steps: steps).write(to: vmDirectory)
    } catch {
      append("cannot write \(ProvisionReport.url(in: vmDirectory).path): \(error)")
    }
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
