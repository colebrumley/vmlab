import Foundation

// MARK: - Keys

/// The per-VM SSH key pair and known-hosts file (R-400, Appendix F): `<vm>/id_ed25519`,
/// `<vm>/id_ed25519.pub`, `<vm>/known_hosts`.
public enum SSHKeys {
  public static let ssh = "/usr/bin/ssh"
  public static let sshKeygen = "/usr/bin/ssh-keygen"

  public static func privateKey(in vmDirectory: URL) -> URL {
    vmDirectory.appending(path: "id_ed25519")
  }

  public static func publicKey(in vmDirectory: URL) -> URL {
    vmDirectory.appending(path: "id_ed25519.pub")
  }

  public static func knownHosts(in vmDirectory: URL) -> URL {
    vmDirectory.appending(path: "known_hosts")
  }

  /// `ssh-keygen -t ed25519 -N "" -C <comment> -f <vm>/id_ed25519 -q`.
  public static func keygenArguments(vmDirectory: URL, comment: String) -> [String] {
    ["-t", "ed25519", "-N", "", "-C", comment, "-f", privateKey(in: vmDirectory).path, "-q"]
  }

  /// `generate` on a thread of its own, so a waiting `ssh-keygen` never holds a thread of the
  /// cooperative pool.
  @discardableResult
  public static func generateDetached(
    in vmDirectory: URL, comment: String, runner: any CommandRunning = ProcessRunner()
  ) async throws(VMLabError) -> String {
    let result: Result<String, VMLabError> = await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        do throws(VMLabError) {
          continuation.resume(
            returning: .success(try generate(in: vmDirectory, comment: comment, runner: runner)))
        } catch {
          continuation.resume(returning: .failure(error))
        }
      }
    }
    return try result.get()
  }

  /// Makes the key pair unless it exists, and returns the public key line.
  @discardableResult
  public static func generate(
    in vmDirectory: URL, comment: String, runner: any CommandRunning = ProcessRunner(),
    sshKeygen: String = SSHKeys.sshKeygen
  ) throws(VMLabError) -> String {
    let files = FileManager.default
    let key = privateKey(in: vmDirectory)
    let pub = publicKey(in: vmDirectory)
    if !(files.fileExists(atPath: key.path) && files.fileExists(atPath: pub.path)) {
      try? files.removeItem(at: key)
      try? files.removeItem(at: pub)
      let arguments = keygenArguments(vmDirectory: vmDirectory, comment: comment)
      guard let result = runner.run(sshKeygen, arguments) else {
        throw VMLabError(
          code: .hostMissingTool, message: "Cannot run \(sshKeygen) to make the VM's SSH key.",
          hint: "ssh-keygen ships with macOS; check that \(sshKeygen) exists.",
          data: ["tool": .string("ssh-keygen")])
      }
      guard result.status == 0 else {
        throw VMLabError(
          code: .provisionFailed, message: "ssh-keygen failed making the VM's SSH key.",
          hint: "See data.log for ssh-keygen's message.",
          data: ["step": .string("ssh-keygen"), "log": .string(result.output)])
      }
    }
    do {
      return try String(contentsOf: pub, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      throw VMLabError(
        code: .provisionFailed, message: "The VM's SSH public key cannot be read: \(error)",
        hint: "Remove id_ed25519 and id_ed25519.pub from the VM directory and recreate the VM.",
        data: ["step": .string("ssh-keygen"), "log": .string(pub.path)])
    }
  }
}

// MARK: - Target

/// Where a guest's sshd listens: QEMU's loopback `hostfwd` port, or the guest's own address.
public struct SSHEndpoint: Codable, Sendable, Hashable {
  public var host: String
  public var port: Int

  public init(host: String, port: Int = 22) {
    self.host = host
    self.port = port
  }

  /// The endpoint a runtime records: the forwarded loopback port when there is one, else the
  /// guest's IP on port 22; nil when neither is known.
  public init?(runtime: VMRuntime?) {
    guard let runtime else { return nil }
    if let port = runtime.sshPort {
      self.init(host: "127.0.0.1", port: port)
    } else if let ip = runtime.ip, !ip.isEmpty {
      self.init(host: ip)
    } else {
      return nil
    }
  }
}

/// Everything `ssh` needs to reach one VM as its image's login user.
public struct SSHTarget: Sendable, Hashable {
  public var vm: String
  public var endpoint: SSHEndpoint
  public var user: String
  public var vmDirectory: URL

  public init(vm: String, endpoint: SSHEndpoint, user: String, vmDirectory: URL) {
    self.vm = vm
    self.endpoint = endpoint
    self.user = user
    self.vmDirectory = vmDirectory
  }

  /// The target of `record` at `endpoint`, as the login user of its image (Appendix H): the pulled
  /// image's record, else the catalogue's, else `admin` for macOS and `root` otherwise.
  public init(record: VMRecord, endpoint: SSHEndpoint, store: Store) {
    self.init(
      vm: record.id, endpoint: endpoint, user: Self.loginUser(of: record, home: store.home),
      vmDirectory: store.directory(of: record.id))
  }

  public static func loginUser(of record: VMRecord, home: URL) -> String {
    if let image = record.image {
      if let pulled = ImageStore(home: home).pulled(image) { return pulled.login.user }
      if let entry = ImageCatalogue.builtin.images.first(where: { $0.name == image }) {
        return entry.login.user
      }
    }
    return record.guest.os == .macos ? "admin" : "root"
  }

  /// The argument vector of `ssh` running `remote` (one string the guest's login shell runs):
  /// the VM's key only, no prompts, the VM's own known-hosts file (a new host key is accepted
  /// once, a changed one refused) under an alias of the VM id so a new forwarded port does not
  /// make a new entry, and keepalives so a dead guest is noticed in about 15 s.
  public func arguments(remote: String, connectTimeoutSeconds: Int = 10) -> [String] {
    options(connectTimeoutSeconds: connectTimeoutSeconds) + [
      "-T",
      "-p", String(endpoint.port),
      "-l", user,
      endpoint.host,
      "--",
      remote,
    ]
  }

  /// The key, host-key and connection options `ssh` and `scp` share.
  public func options(connectTimeoutSeconds: Int = 10) -> [String] {
    [
      "-i", SSHKeys.privateKey(in: vmDirectory).path,
      "-o", "BatchMode=yes",
      "-o", "StrictHostKeyChecking=accept-new",
      "-o", "UserKnownHostsFile=\(SSHKeys.knownHosts(in: vmDirectory).path)",
      "-o", "GlobalKnownHostsFile=/dev/null",
      "-o", "HostKeyAlias=\(vm)",
      "-o", "IdentitiesOnly=yes",
      "-o", "IdentityAgent=none",
      "-o", "PasswordAuthentication=no",
      "-o", "KbdInteractiveAuthentication=no",
      "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
      "-o", "ServerAliveInterval=5",
      "-o", "ServerAliveCountMax=3",
      "-o", "LogLevel=ERROR",
      "-F", "/dev/null",
    ]
  }
}

// MARK: - Readiness

/// Whether a freshly started guest answers SSH (R-400): `vm_lifecycle start` waits on it.
public protocol GuestReadiness: Sendable {
  /// Waits until the guest answers or `timeout` passes; returns nil when it answered, else a
  /// warning for the start result.
  func wait(for target: SSHTarget, timeout: Duration) async -> String?
}

/// Runs `ssh ... true` every two seconds until it exits 0 or the boot timeout passes.
public struct SSHReadiness: GuestReadiness {
  public var ssh: String
  public var interval: Duration

  public init(ssh: String = SSHKeys.ssh, interval: Duration = .seconds(2)) {
    self.ssh = ssh
    self.interval = interval
  }

  public func wait(for target: SSHTarget, timeout: Duration) async -> String? {
    let deadline = ContinuousClock.now + timeout
    var lastError = "no answer"
    while ContinuousClock.now < deadline, !Task.isCancelled {
      let errors = Pipe()
      let attempt = Task.detached {
        errors.fileHandleForReading.readDataToEndOfFile()
      }
      let left = deadline - ContinuousClock.now
      let outcome = try? await HostProcess.run(
        ssh, target.arguments(remote: "true", connectTimeoutSeconds: 5),
        stderr: errors.fileHandleForWriting, timeout: min(left, .seconds(15)))
      try? errors.fileHandleForWriting.close()
      let text = String(decoding: await attempt.value, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let outcome, outcome.status == 0, !outcome.timedOut { return nil }
      if !text.isEmpty { lastError = text }
      do { try await Task.sleep(for: interval) } catch { break }
    }
    let seconds = timeout.components.seconds
    return "ssh_unreachable: \(target.vm) did not answer SSH at \(target.endpoint.host):"
      + "\(target.endpoint.port) within \(seconds) s (\(lastError)); it is running, retry vm_exec "
      + "later or read vm_serial"
  }
}

extension ResourceLimits {
  /// Appendix G: how long a start waits for SSH. Linux 180 s, macOS 300 s, TCG 900 s.
  public static func bootTimeout(profile: Profile, os: GuestSpec.OS) -> Duration {
    if profile == .qemuTCG { return .seconds(900) }
    return os == .macos ? .seconds(300) : .seconds(180)
  }
}
