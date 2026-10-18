import Foundation
import Testing
import VMLabCore

@Suite struct PathPolicyTests {
  /// A home and an outside directory under a fresh temporary root; the policy's roots are the
  /// fake home and /tmp only (no $TMPDIR, so the outside directory is really outside).
  struct Fixture {
    let base: URL
    let home: URL
    let outside: URL
    let policy: PathPolicy

    init() throws {
      base = URL(filePath: PathPolicy.canonical(FileManager.default.temporaryDirectory.path))
        .appending(path: "vmlab-paths-\(UUID().uuidString)")
      home = base.appending(path: "home")
      outside = base.appending(path: "outside")
      for dir in [home, outside] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      }
      policy = PathPolicy(roots: [home.path, "/tmp"])
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }
  }

  @Test func pathsUnderTheHomeOrTmpPass() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    #expect(
      try f.policy.check(f.home.path + "/a/b.txt", field: "local").path
        == f.home.path + "/a/b.txt")
    #expect(try f.policy.check(f.home.path, field: "local").path == f.home.path)
    // /tmp is a symlink to /private/tmp on macOS; both spellings pass and resolve alike.
    #expect(try f.policy.check("/tmp/x", field: "local").path == "/private/tmp/x")
    #expect(try f.policy.check("/private/tmp/x", field: "local").path == "/private/tmp/x")
  }

  @Test func pathsOutsideAreRefused() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    for path in [
      "/etc/passwd", "/", f.outside.path + "/x", f.home.path + "/../outside/x",
      f.home.path + "x/sibling-with-a-common-prefix",
    ] {
      let error = #expect(throws: VMLabError.self) { try f.policy.check(path, field: "local") }
      #expect(error?.code == .invalidRequest)
      #expect(error?.data["field"] == .string("local"))
      #expect(error?.hint.contains("allowAnyPath") == true)
    }
    let relative = #expect(throws: VMLabError.self) { try f.policy.check("a/b", field: "path") }
    #expect(relative?.data["field"] == .string("path"))
  }

  @Test func symlinksOutOfTheHomeAreFollowed() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let link = f.home.appending(path: "escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.outside)
    let error = #expect(throws: VMLabError.self) {
      try f.policy.check(link.path + "/secret", field: "local")
    }
    #expect(error?.data["resolved"] == .string(f.outside.path + "/secret"))
    // A dangling link would be followed by a write, so its target counts.
    let dangling = f.home.appending(path: "dangling")
    try FileManager.default.createSymbolicLink(
      atPath: dangling.path, withDestinationPath: f.outside.path + "/new-file")
    #expect(throws: VMLabError.self) { try f.policy.check(dangling.path, field: "local") }
    // A link that stays inside is fine.
    let inner = f.home.appending(path: "inner")
    try FileManager.default.createSymbolicLink(at: inner, withDestinationURL: f.home)
    #expect(try f.policy.check(inner.path + "/x", field: "local").path == f.home.path + "/x")
  }

  @Test func allowAnyPathInConfigLiftsTheRestriction() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let vmlabHome = f.base.appending(path: "vmlab")
    try FileManager.default.createDirectory(at: vmlabHome, withIntermediateDirectories: true)
    let strict = PathPolicy.load(home: vmlabHome, userHome: f.home, temporaryDirectory: f.home)
    #expect(!strict.allowAnyPath)
    #expect(throws: VMLabError.self) { try strict.check("/etc/hosts", field: "local") }

    try Data(#"{"allowAnyPath": true, "reserveGB": 4}"#.utf8).write(
      to: VMLabConfig.url(home: vmlabHome))
    let open = PathPolicy.load(home: vmlabHome, userHome: f.home, temporaryDirectory: f.home)
    #expect(open.allowAnyPath)
    #expect(try open.check("/etc/hosts", field: "local").path == "/private/etc/hosts")
    // Still absolute only.
    #expect(throws: VMLabError.self) { try open.check("hosts", field: "local") }

    try Data("not json".utf8).write(to: VMLabConfig.url(home: vmlabHome))
    #expect(!VMLabConfig.load(home: vmlabHome).allowAnyPath)
  }

  @Test func defaultRootsAreTheUsersHomeTmpAndTemporaryDirectory() {
    let policy = PathPolicy.load(home: URL(filePath: "/nonexistent-vmlab-home"))
    #expect(!policy.allowAnyPath)
    let home = PathPolicy.canonical(FileManager.default.homeDirectoryForCurrentUser.path)
    #expect(policy.roots.contains(home))
    #expect(policy.roots.contains("/private/tmp"))
    #expect(
      policy.roots.contains(PathPolicy.canonical(FileManager.default.temporaryDirectory.path)))
  }
}

@Suite struct SharePathPolicyTests {
  @Test func aShareOutsideTheHomeIsRefusedAtCreate() async throws {
    let f = try VMManagerTests.Fixture()
    var draft = VMRecord(
      id: "", name: "shared", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [])
    draft.share = SharedDirSpec(host: "/etc", guest: "/mnt/host")
    let error = await #expect(throws: VMLabError.self) {
      try await f.manager.create(draft, plan: f.plan([.sharedDir]))
    }
    #expect(error?.data["field"] == .string("share.host"))
    #expect(try f.store.list().records.isEmpty)
  }

  @Test func anAllowedShareIsRecordedCanonical() async throws {
    let f = try VMManagerTests.Fixture()
    var draft = VMRecord(
      id: "", name: "shared", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [])
    draft.share = SharedDirSpec(host: "/tmp/./vmlab-share", guest: "/mnt/host")
    let created = try await f.manager.create(draft, plan: f.plan([.sharedDir]))
    #expect(created.share?.host == "/private/tmp/vmlab-share")
  }
}
