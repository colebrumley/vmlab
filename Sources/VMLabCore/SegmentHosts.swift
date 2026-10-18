import Foundation

/// Names on a segment (R-902): every running member's `/etc/hosts` carries one marker-delimited
/// block with a line `<ip> <vm-name> <vm-name>.<segment>` per member. The block is rewritten whole
/// (so a join and a leave are the same operation, and repeating it changes nothing) under a lock in
/// the guest, so concurrent starts of a fleet never interleave their writes.
public protocol SegmentNaming: Sendable {
  /// Writes `segment`'s block into each target's `/etc/hosts`; returns, per target VM id, the
  /// error of the ones that failed.
  func publish(_ segment: Segment, to targets: [SSHTarget]) async -> [String: VMLabError]
}

public enum SegmentHosts {
  public static func begin(_ segment: String) -> String { "# vmlab segment \(segment) begin" }
  public static func end(_ segment: String) -> String { "# vmlab segment \(segment) end" }

  /// The block's lines, in join order.
  public static func lines(_ segment: Segment) -> [String] {
    segment.members.map { "\($0.address) \($0.name) \($0.name).\(segment.name)" }
  }

  /// The guest script (run as root, the lines on stdin): drop the old block, append the new one.
  /// The lock is `/var/run/vmlab-hosts.lock`, a root-only directory both Linux (where it is
  /// /run) and macOS (which has no /run) have (CX-17); a lock that cannot be opened, or a guest
  /// without `flock` (macOS), only loses the serialization, never the update. (The braces keep
  /// the `2>/dev/null` off the rest of the script, whose stderr is the error's text.)
  public static func script(_ segment: Segment) -> String {
    let begin = RemoteShell.quote(begin(segment.name))
    let end = RemoteShell.quote(end(segment.name))
    return """
      set -e
      { command exec 9>/var/run/vmlab-hosts.lock; } 2>/dev/null || true
      flock 9 2>/dev/null || true
      t=$(mktemp)
      awk -v b=\(begin) -v e=\(end) '$0==b{s=1;next} $0==e{s=0;next} !s' /etc/hosts > "$t"
      { printf '%s\\n' \(begin); cat; printf '%s\\n' \(end); } >> "$t"
      cat "$t" > /etc/hosts
      rm -f "$t"
      """
  }
}

/// Publishes the block over SSH with each member's own key, in parallel.
public struct SSHSegmentHosts: SegmentNaming {
  public var exec: @Sendable (SSHTarget, ExecRequest) async throws(VMLabError) -> ExecResult

  public init(
    exec: @escaping @Sendable (SSHTarget, ExecRequest) async throws(VMLabError) -> ExecResult = {
      target, request throws(VMLabError) in
      try await SSHExecChannel(target: target).run(request)
    }
  ) {
    self.exec = exec
  }

  public func publish(_ segment: Segment, to targets: [SSHTarget]) async -> [String: VMLabError] {
    let request = ExecRequest(
      command: SegmentHosts.script(segment),
      stdin: Data(SegmentHosts.lines(segment).map { $0 + "\n" }.joined().utf8),
      timeout: .seconds(30), user: "root", via: .ssh)
    let exec = exec
    return await withTaskGroup(of: (String, VMLabError?).self) { group in
      for target in targets {
        group.addTask {
          do throws(VMLabError) {
            let result = try await exec(target, request)
            guard result.exitCode == 0 else {
              return (
                target.vm,
                VMLabError(
                  code: .engineError,
                  message: "updating /etc/hosts exited \(result.exitCode): \(result.stderr)",
                  hint: "Run the update again by restarting the VM.",
                  data: ["engine": .string("ssh"), "raw": .string(result.stderr)])
              )
            }
            return (target.vm, nil)
          } catch {
            return (target.vm, error)
          }
        }
      }
      var failed: [String: VMLabError] = [:]
      for await (vm, error) in group { if let error { failed[vm] = error } }
      return failed
    }
  }
}

extension VMManager {
  /// Rewrites the names block of `name` on every running member that has an SSH endpoint now and
  /// is not busy with another lifecycle action in this process.
  /// Returns warnings for `focus` (the VM whose start or destroy caused it) only: another member
  /// that does not answer yet gets the block when its own start publishes it.
  func publishNames(_ name: String, focus: String) async -> [String] {
    guard let segment = try? segments.load(name) else { return [] }
    var targets: [SSHTarget] = []
    for member in segment.members {
      // A member busy with its own start or destroy is left alone: its start publishes the block
      // itself, and an SSH session into a VM being destroyed would recreate its directory.
      if member.vm != focus, busy.contains(member.vm) { continue }
      guard let record = try? store.load(id: member.vm), record.state == .running,
        record.features.contains(.execSSH),
        let backend = try? backends.backend(for: record.profile),
        let endpoint = await backend.sshEndpoint(record, timeout: .zero)
      else { continue }
      targets.append(SSHTarget(record: record, endpoint: endpoint, store: store))
    }
    guard !targets.isEmpty else { return [] }
    let failed = await naming.publish(segment, to: targets)
    var warnings: [String] = []
    for (vm, error) in failed.sorted(by: { $0.key < $1.key }) {
      let message =
        "hosts_not_updated: \(vm)'s /etc/hosts lacks segment \(name)'s names: "
        + error.message
      await log(vm, message, level: .warning)
      if vm == focus { warnings.append(message) }
    }
    return warnings
  }
}
