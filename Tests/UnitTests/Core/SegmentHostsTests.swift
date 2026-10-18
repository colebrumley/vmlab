import Foundation
import Testing
import VMLabCore

@Suite struct SegmentHostsTests {
  static func segment(_ members: [(String, String)]) -> Segment {
    var segment = Segment(name: "cluster", index: 3, createdAt: Date())
    segment.members = members.enumerated().map { index, member in
      SegmentMember(
        vm: "vm-aaaaa\(index)", name: member.0, address: member.1, mac: "52:54:5e:00:00:0\(index)",
        joinedAt: Date())
    }
    return segment
  }

  /// Runs the guest script on the host against a copy of an `/etc/hosts`. The lock path is left
  /// as it is (CX-17): this macOS host has no /run, as a macOS guest has none, and a non-root
  /// run cannot create the lock at all; the names must be published regardless.
  /// The script and its wait run on a thread of their own, off the cooperative pool.
  static func apply(_ segment: Segment, to hosts: URL, shell: String = "/bin/sh") async throws
    -> String
  {
    let script = SegmentHosts.script(segment)
      .replacingOccurrences(of: "/etc/hosts", with: hosts.path)
    let input = Data(SegmentHosts.lines(segment).map { $0 + "\n" }.joined().utf8)
    let status = try await OffPool.run { () throws(any Error) -> Int32 in
      let process = Process()
      process.executableURL = URL(filePath: shell)
      process.arguments = ["-c", script]
      let pipe = Pipe()
      process.standardInput = pipe
      try process.run()
      pipe.fileHandleForWriting.write(input)
      try pipe.fileHandleForWriting.close()
      process.waitUntilExit()
      return process.terminationStatus
    }
    #expect(status == 0)
    return try String(contentsOf: hosts, encoding: .utf8)
  }

  @Test func blockIsRewrittenWholeAndIdempotent() async throws {
    let hosts = FileManager.default.temporaryDirectory.appending(path: "hosts-\(UUID())")
    defer { try? FileManager.default.removeItem(at: hosts) }
    let original = "127.0.0.1 localhost\n::1 localhost ip6-localhost\n"
    try original.write(to: hosts, atomically: true, encoding: .utf8)

    let two = Self.segment([("node-1", "10.3.0.10"), ("node-2", "10.3.0.11")])
    let block = """
      # vmlab segment cluster begin
      10.3.0.10 node-1 node-1.cluster
      10.3.0.11 node-2 node-2.cluster
      # vmlab segment cluster end

      """
    #expect(try await Self.apply(two, to: hosts) == original + block)
    #expect(try await Self.apply(two, to: hosts) == original + block)

    // A leave: the block shrinks, the rest of the file stays.
    let one = Self.segment([("node-2", "10.3.0.11")])
    #expect(
      try await Self.apply(one, to: hosts)
        == original + """
          # vmlab segment cluster begin
          10.3.0.11 node-2 node-2.cluster
          # vmlab segment cluster end

          """)
  }

  /// CX-17: the lock lives where both Linux and macOS have a directory, and a lock that cannot
  /// be made never stops the update; checked with macOS's /bin/sh and, when present, dash.
  @Test func scriptRunsWhereThereIsNoRun() async throws {
    #expect(!SegmentHosts.script(Self.segment([])).contains(" 9>/run/"))
    #expect(FileManager.default.fileExists(atPath: "/var/run"))
    for shell in ["/bin/sh", "/bin/zsh", "/bin/dash"]
    where FileManager.default.isExecutableFile(atPath: shell) {
      let hosts = FileManager.default.temporaryDirectory.appending(path: "hosts-\(UUID())")
      defer { try? FileManager.default.removeItem(at: hosts) }
      try "127.0.0.1 localhost\n".write(to: hosts, atomically: true, encoding: .utf8)
      let text = try await Self.apply(Self.segment([("a", "10.3.0.10")]), to: hosts, shell: shell)
      #expect(text.contains("10.3.0.10 a a.cluster"), "\(shell)")
    }
  }

  @Test func publishRunsAsRootWithTheLinesOnStdin() async {
    let seen = LockedRequests()
    let naming = SSHSegmentHosts { target, request throws(VMLabError) in
      seen.append(target.vm, request)
      if target.vm == "vm-bad" {
        throw VMLabError(code: .guestUnreachable, message: "no", hint: "")
      }
      return ExecResult(exitCode: 0, stdout: "", stderr: "", durationMs: 1)
    }
    let targets = ["vm-good", "vm-bad"].map {
      SSHTarget(
        vm: $0, endpoint: SSHEndpoint(host: "127.0.0.1", port: 2222), user: "debian",
        vmDirectory: URL(filePath: "/tmp/\($0)"))
    }
    let failed = await naming.publish(Self.segment([("node-1", "10.3.0.10")]), to: targets)
    #expect(failed.keys.sorted() == ["vm-bad"])
    let requests = seen.all()
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.1.user == "root" })
    #expect(requests.first?.1.stdin == Data("10.3.0.10 node-1 node-1.cluster\n".utf8))
  }
}

final class LockedRequests: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [(String, ExecRequest)] = []

  func append(_ vm: String, _ request: ExecRequest) {
    lock.withLock { requests.append((vm, request)) }
  }
  func all() -> [(String, ExecRequest)] { lock.withLock { requests } }
}
