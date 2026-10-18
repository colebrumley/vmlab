import Foundation
import Testing
import VMLabCore
import VMLabMCP
import VMLabQEMU
import VMLabVZ

@Suite struct FileIntegrationTests {
  /// R-404 Verify (integration): push a 5 MB file, pull it back, bytes equal; a directory goes
  /// both ways recursively; a pull with no local path lands in `<vm>/pulled/`.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(5)))
  func pushAndPullOnDebian() async throws {
    let guest = try await QEMUGuest.boot(features: [.serial, .execSSH, .netNAT])
    let registry = BackendRegistry()
    registry.register(guest.backend)
    let context = ToolContext(home: guest.home, backends: registry)
    func file(_ arguments: [String: JSONValue]) async throws(VMLabError) -> JSONValue {
      var arguments = arguments
      arguments["vm"] = .string(guest.record.id)
      return try await ToolHandlers.call("vm_file", arguments: .object(arguments), context: context)
        .value
    }
    let work = guest.home.appending(path: "work")
    do {
      try FileManager.default.createDirectory(
        at: work.appending(path: "tree/sub"), withIntermediateDirectories: true)
      var bytes = Data(count: 5 * 1024 * 1024)
      for i in stride(from: 0, to: bytes.count, by: 4096) {
        bytes[i] = UInt8(truncatingIfNeeded: i / 4096)
      }
      let big = work.appending(path: "big.bin")
      try bytes.write(to: big)
      try Data("leaf\n".utf8).write(to: work.appending(path: "tree/sub/leaf.txt"))

      let pushed = try await file([
        "action": .string("push"), "local": .string(big.path), "remote": .string("/tmp/big.bin"),
      ])
      #expect(pushed["bytes"] == .number(Double(bytes.count)))
      #expect(pushed["path"] == .string("/tmp/big.bin"))
      let back = work.appending(path: "back.bin")
      let pulled = try await file([
        "action": .string("pull"), "remote": .string("/tmp/big.bin"), "local": .string(back.path),
      ])
      #expect(pulled["bytes"] == .number(Double(bytes.count)))
      #expect(try Data(contentsOf: back) == bytes)

      _ = try await file([
        "action": .string("push"), "local": .string(work.appending(path: "tree").path),
        "remote": .string("/tmp/tree"),
      ])
      let tree = try await file(["action": .string("pull"), "remote": .string("/tmp/tree")])
      let treePath = try #require(tree["path"]?.stringValue)
      #expect(treePath.hasSuffix("/pulled/tree"))
      #expect(tree["bytes"] == .number(5))
      #expect(
        try String(contentsOfFile: treePath + "/sub/leaf.txt", encoding: .utf8) == "leaf\n")

      let missing = await #expect(throws: VMLabError.self) {
        try await file(["action": .string("pull"), "remote": .string("/no/such/file")])
      }
      #expect(missing?.code == .invalidRequest)
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-404 Verify (integration), QEMU half: a 9p shared directory shows a host-written file
  /// inside the guest within 2 s. Ubuntu's cloud kernel has 9p; Debian's cloud kernel does not
  /// (`CONFIG_NET_9P` is unset), so this runs on `ubuntu-24.04-arm64`.
  @Test(
    .enabled(if: integrationEnabled),
    .enabled(if: pulled("ubuntu-24.04-arm64"), "needs vmlab images pull ubuntu-24.04-arm64"),
    .timeLimit(.minutes(8)))
  func sharedDirectoryOverNinePOnUbuntu() async throws {
    let host = URL(filePath: "/tmp/vmlab-share-\(getpid())")
    try? FileManager.default.removeItem(at: host)
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: host) }
    let guest = try await QEMUGuest.boot(
      features: [.serial, .execSSH, .netNAT, .sharedDir], image: "ubuntu-24.04-arm64",
      share: SharedDirSpec(host: host.path, guest: "/mnt/host"))
    do {
      let vm = try await guest.manager.attach(guest.record.id)
      let ssh = try vm.channel(.execSSH)
      // cloud-init's mounts module runs during boot, possibly after sshd answers.
      let deadline = ContinuousClock.now + .seconds(120)
      var mounted = false
      while !mounted, ContinuousClock.now < deadline {
        mounted =
          try await ssh.run(ExecRequest(command: "mountpoint -q /mnt/host")).exitCode == 0
        if !mounted { try await Task.sleep(for: .seconds(2)) }
      }
      #expect(mounted, "/mnt/host never mounted")
      let fstype = try await ssh.run(ExecRequest(command: "findmnt -no FSTYPE /mnt/host"))
      #expect(fstype.stdout == "9p\n", "\(fstype)")

      try Data("from the host\n".utf8).write(to: host.appending(path: "hello.txt"))
      let written = ContinuousClock.now
      var seen = ""
      while ContinuousClock.now - written < .seconds(2) {
        seen = try await ssh.run(ExecRequest(command: "cat /mnt/host/hello.txt 2>/dev/null"))
          .stdout
        if seen == "from the host\n" { break }
        try await Task.sleep(for: .milliseconds(200))
      }
      #expect(seen == "from the host\n")
      #expect(ContinuousClock.now - written < .seconds(2))

      let back = try await ssh.run(
        ExecRequest(command: "echo from the guest | sudo tee /mnt/host/back.txt >/dev/null"))
      #expect(back.exitCode == 0, "\(back)")
      #expect(
        try String(contentsOf: host.appending(path: "back.txt"), encoding: .utf8)
          == "from the guest\n")
    } catch {
      await guest.shutdown()
      throw error
    }
    await guest.shutdown()
  }

  /// R-404 Verify (integration), VZ half: R-603's virtiofs share shows a host-written file in the
  /// guest within 2 s, and a guest write reaches the host.
  @Test(.enabled(if: VZRunnerIntegrationTests.ready), .timeLimit(.minutes(8)))
  func sharedDirectoryOverVirtiofsOnVZ() async throws {
    let host = URL(filePath: "/tmp/vmlab-test-\(getpid())-vzshare")
    try? FileManager.default.removeItem(at: host)
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: host) }
    let guest = try await VZGuest.boot(
      features: [.execSSH, .sharedDir], tag: "v", share: SharedDirSpec(host: host.path))
    defer { guest.cleanUp() }
    // cloud-init mounts it shortly after SSH comes up.
    #expect(await guest.ssh("mountpoint -q /mnt/host", within: .seconds(300))?.status == 0)
    try "from the host\n".write(
      to: host.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
    let written = ContinuousClock.now
    let seen = await guest.ssh("cat /mnt/host/hello.txt", within: .seconds(10))
    #expect(seen?.output == "from the host\n")
    print("host file seen in the VZ guest after \(ContinuousClock.now - written)")
    #expect(ContinuousClock.now - written < .seconds(2))
    let back = await guest.ssh("echo from the guest | sudo tee /mnt/host/back.txt >/dev/null")
    #expect(back?.status == 0)
    #expect(
      try String(contentsOf: host.appending(path: "back.txt"), encoding: .utf8)
        == "from the guest\n")
  }
}

/// Whether `name` is pulled into `~/.vmlab/images`.
func pulled(_ name: String) -> Bool {
  FileManager.default.fileExists(
    atPath: FileManager.default.homeDirectoryForCurrentUser.appending(
      path: ".vmlab/images/\(name)/image.json"
    ).path)
}
