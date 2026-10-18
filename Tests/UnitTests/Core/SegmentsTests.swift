import Foundation
import Testing
import VMLabCore

@Suite struct SegmentsTests {
  static func home() -> URL {
    // Short: port socket paths must fit sun_path.
    URL(filePath: "/tmp/vsg-\(UInt32.random(in: 0...UInt32.max))")
  }

  static func record(_ id: String, _ name: String) -> VMRecord {
    VMRecord(
      id: id, name: name, profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [.netSegment])
  }

  @Test func subnetsAndAddressesFollowJoinOrder() throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let segments = SegmentStore(home: home, switchBinary: nil)
    let a = try segments.create("a")
    let b = try segments.create("b")
    #expect((a.index, a.subnet) == (1, "10.1.0.0/24"))
    #expect(b.subnet == "10.2.0.0/24")

    let one = try segments.join("a", vm: Self.record("vm-aaaaaa", "node-1"))
    let two = try segments.join("a", vm: Self.record("vm-bbbbbb", "node-2"))
    #expect(one.address == "10.1.0.10")
    #expect(two.address == "10.1.0.11")
    #expect(one.mac == SegmentAttachment.mac(for: "vm-aaaaaa"))
    #expect(one.mac != two.mac)
    // Joining again keeps the address.
    #expect(try segments.join("a", vm: Self.record("vm-aaaaaa", "node-1")) == one)
    #expect(try segments.load("a").members.map(\.name) == ["node-1", "node-2"])

    try segments.leave("a", vm: "vm-aaaaaa")
    #expect(try segments.join("a", vm: Self.record("vm-cccccc", "node-3")).address == "10.1.0.10")

    // A destroyed segment's subnet is reused.
    try segments.destroy("b")
    #expect(try segments.create("c").index == 2)
    #expect(segments.list().map(\.name) == ["a", "c"])
  }

  /// CX-18: destroy takes `segment-<name>`'s lock, so a join that holds it (here, a member
  /// written while the test holds the lock) is seen and the segment is kept, not deleted.
  @Test func destroyWaitsForTheSegmentLockAndSeesAJoin() async throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let segments = SegmentStore(home: home, switchBinary: nil)
    var segment = try segments.create("lab")
    let lock = try #require(
      FileLock.tryLock(home.appending(path: "locks/segment-lab.lock").path))
    let destroying = Task.detached { () -> VMLabError? in
      do { try segments.destroy("lab") } catch { return error as? VMLabError }
      return nil
    }
    try await Task.sleep(for: .milliseconds(200))
    segment.members = [
      SegmentMember(
        vm: "vm-aaaaaa", name: "late", address: "10.1.0.10", mac: "52:54:5e:00:00:01",
        joinedAt: Date())
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(segment).write(to: segments.recordURL(of: "lab"), options: .atomic)
    lock.unlock()
    let error = await destroying.value
    #expect(error?.code == .wrongState)
    #expect(try segments.load("lab").members.map(\.name) == ["late"])
  }

  /// CX-18: a join racing a destroy recreates the segment rather than failing or writing into
  /// a removed directory.
  @Test func aJoinAfterADestroyRecreatesTheSegment() throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let segments = SegmentStore(home: home, switchBinary: nil)
    try segments.create("lab")
    try segments.destroy("lab")
    #expect(try segments.join("lab", vm: Self.record("vm-aaaaaa", "x")).segment == "lab")
    #expect(try segments.load("lab").members.count == 1)
  }

  @Test func joiningAMissingSegmentCreatesIt() throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let segments = SegmentStore(home: home, switchBinary: nil)
    #expect(try segments.join("new", vm: Self.record("vm-aaaaaa", "x")).address == "10.1.0.10")
    #expect(try segments.load("new").json["members"]?.arrayValue?.count == 1)
  }

  @Test func refusals() throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let segments = SegmentStore(home: home, switchBinary: nil)
    for bad in ["", "Upper", "-x", String(repeating: "a", count: 33), "a/b"] {
      #expect(throws: VMLabError.self) { try segments.create(bad) }
    }
    try segments.create("busy")
    #expect { try segments.create("busy") } throws: {
      ($0 as? VMLabError)?.code == .invalidRequest
    }
    _ = try segments.join("busy", vm: Self.record("vm-aaaaaa", "x"))
    #expect { try segments.destroy("busy") } throws: { ($0 as? VMLabError)?.code == .wrongState }
    #expect { try segments.load("nope") } throws: {
      ($0 as? VMLabError)?.code == .invalidRequest
    }
  }

  @Test func missingSwitchBinaryIsHostMissingTool() async throws {
    let home = Self.home()
    defer { try? FileManager.default.removeItem(at: home) }
    let segments = SegmentStore(home: home, switchBinary: "/nonexistent/vmlab-switch")
    try segments.create("s")
    await #expect {
      try await segments.startSwitch("s")
    } throws: { ($0 as? VMLabError)?.code == .hostMissingTool }
  }

  @Test func childSeedGetsTheStaticSegmentAddress() throws {
    var config = CloudInitConfig(
      instanceID: "vm-aaaaaa", hostname: "node-1", user: "debian", sshPublicKey: "ssh-ed25519 K")
    config.segment = SegmentNIC(
      primaryMAC: "52:54:00:01:02:03", mac: SegmentAttachment.mac(for: "vm-aaaaaa"),
      address: "10.1.0.10")
    let text = try #require(CloudInit.networkConfig(config))
    #expect(text.contains("\"10.1.0.10/24\""))
    #expect(text.contains(SegmentAttachment.mac(for: "vm-aaaaaa")))
  }
}
