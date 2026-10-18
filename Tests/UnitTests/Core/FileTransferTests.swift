import Foundation
import Testing

@testable import VMLabCore

/// `SSHFileTransfer` against a stand-in `scp` that drops the `user@host:` prefix and copies with
/// `cp -R`, so destination rules and byte counts are checked on the host.
@Suite struct FileTransferTests {
  struct Fixture {
    let dir: URL
    let transfer: SSHFileTransfer

    init(scpBody: String? = nil) throws {
      dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-file-\(UUID())")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let scp = dir.appending(path: "scp")
      let body =
        scpBody ?? """
          for a; do src=$dst; dst=$a; done
          src=${src#*@127.0.0.1:}
          dst=${dst#*@127.0.0.1:}
          exec cp -R "$src" "$dst"
          """
      try ("#!/bin/sh\n" + body + "\n").write(to: scp, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scp.path)
      let target = SSHTarget(
        vm: "vm-t", endpoint: SSHEndpoint(host: "127.0.0.1", port: 2222), user: "debian",
        vmDirectory: dir)
      transfer = SSHFileTransfer(target: target, scp: scp.path)
    }

    func write(_ name: String, bytes: Int) throws -> URL {
      let url = dir.appending(path: name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 0x61, count: bytes).write(to: url)
      return url
    }
  }

  @Test func argumentVector() throws {
    let f = try Fixture()
    let args = f.transfer.arguments(source: "/a", destination: f.transfer.remoteSpec("/b c"))
    #expect(Array(args.prefix(5)) == ["-s", "-r", "-q", "-P", "2222"])
    #expect(args.contains("UserKnownHostsFile=\(f.dir.path)/known_hosts"))
    #expect(Array(args.suffix(2)) == ["/a", "debian@127.0.0.1:/b c"])
    let v6 = SSHFileTransfer(
      target: SSHTarget(
        vm: "v", endpoint: SSHEndpoint(host: "fe80::1"), user: "u", vmDirectory: f.dir))
    #expect(v6.remoteSpec("/x") == "u@[fe80::1]:/x")
  }

  @Test func pushReportsTheBytes() async throws {
    let f = try Fixture()
    let file = try f.write("in/file.bin", bytes: 5000)
    _ = try f.write("in/sub/more.bin", bytes: 300)
    let target = f.dir.appending(path: "guest-copy")
    let one = try await f.transfer.push(local: file, remote: target.path)
    #expect(one == FileTransferResult(bytes: 5000, path: target.path))
    let tree = try await f.transfer.push(
      local: f.dir.appending(path: "in"), remote: f.dir.appending(path: "tree").path)
    #expect(tree.bytes == 5300)
    #expect(FileManager.default.fileExists(atPath: f.dir.appending(path: "tree/sub/more.bin").path))
  }

  @Test func pullDefaultsToThePulledDirectory() async throws {
    let f = try Fixture()
    let file = try f.write("guest/data.txt", bytes: 42)
    let pulled = try await f.transfer.pull(remote: file.path, local: nil)
    #expect(pulled.path == f.dir.appending(path: "pulled/data.txt").path)
    #expect(pulled.bytes == 42)
    _ = try f.write("guest/tree/a", bytes: 1)
    let first = try await f.transfer.pull(
      remote: f.dir.appending(path: "guest/tree/").path, local: nil)
    let again = try await f.transfer.pull(
      remote: f.dir.appending(path: "guest/tree").path, local: nil)
    #expect(first.path == again.path)
    #expect(!FileManager.default.fileExists(atPath: again.path + "/tree"))

    let into = f.dir.appending(path: "dest")
    try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
    let inside = try await f.transfer.pull(remote: file.path, local: into)
    #expect(inside.path == into.appending(path: "data.txt").path)
  }

  @Test func errorsAreMapped() async throws {
    let f = try Fixture()
    let missing = await #expect(throws: VMLabError.self) {
      try await f.transfer.push(local: f.dir.appending(path: "nope"), remote: "/x")
    }
    #expect(missing?.data["field"] == .string("local"))
    let empty = await #expect(throws: VMLabError.self) {
      try await f.transfer.pull(remote: "", local: nil)
    }
    #expect(empty?.data["field"] == .string("remote"))

    let noFile = try Fixture(scpBody: "echo 'scp: /x: No such file or directory' >&2; exit 1")
    let remote = await #expect(throws: VMLabError.self) {
      try await noFile.transfer.pull(remote: "/x", local: nil)
    }
    #expect(remote?.code == .invalidRequest)
    #expect(remote?.data["reason"] == .string("scp: /x: No such file or directory"))

    let down = try Fixture(
      scpBody: "echo 'ssh: connect to host 127.0.0.1 port 2222: Connection refused' >&2; exit 255")
    let unreachable = await #expect(throws: VMLabError.self) {
      try await down.transfer.pull(remote: "/x", local: nil)
    }
    #expect(unreachable?.code == .guestUnreachable)
  }
}

@Suite struct FileTransferTimeoutTests {
  /// R-1101: a pull stopped by its timeout reports what had landed.
  @Test func aTimedOutPullCarriesTheBytesSoFar() async throws {
    let f = try FileTransferTests.Fixture(
      scpBody: """
        for a; do dst=$a; done
        printf 'partial' > "$dst"
        exec sleep 30
        """)
    let error = await #expect(throws: VMLabError.self) {
      try await f.transfer.pull(remote: "/big", local: nil, timeout: .seconds(5))
    }
    #expect(error?.code == .timeout)
    #expect(error?.data["bytesCopied"] == .number(7))
    #expect(error?.data["path"] == .string(f.dir.appending(path: "pulled/big").path))
  }
}
