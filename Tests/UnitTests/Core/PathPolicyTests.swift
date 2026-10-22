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

  /// CR-4: boot images are host paths the model names; they pass the same policy.
  @Test func bootPathsOutsideTheHomeAreRefusedAtCreate() async throws {
    let f = try VMManagerTests.Fixture()
    for (field, boot) in [
      ("boot.kernel", BootSpec(mode: .kernel, kernel: "/etc/hosts")),
      ("boot.initrd", BootSpec(mode: .kernel, kernel: "/tmp/k", initrd: "/etc/hosts")),
      ("boot.dtb", BootSpec(mode: .kernel, kernel: "/tmp/k", dtb: "/etc/hosts")),
      ("boot.firmware", BootSpec(mode: .firmware, firmware: "/etc/hosts")),
      ("boot.binary", BootSpec(mode: .binary, binary: "/etc/hosts", loadAddress: "0x40000000")),
    ] {
      var draft = VMRecord(
        id: "", name: "booted", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [])
      draft.boot = boot
      let error = await #expect(throws: VMLabError.self) {
        try await f.manager.create(draft, plan: f.plan([.directKernelBoot]))
      }
      #expect(error?.data["field"] == .string(field))
    }
    #expect(try f.store.list().records.isEmpty)
    var draft = VMRecord(
      id: "", name: "booted", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [])
    draft.boot = BootSpec(mode: .kernel, kernel: "/tmp/./vmlab-kernel")
    let created = try await f.manager.create(draft, plan: f.plan([.directKernelBoot]))
    #expect(created.boot?.kernel == "/private/tmp/vmlab-kernel")
  }
}

/// Reads versus writes: a write lands only under /tmp, `$TMPDIR`, `~/vmlab-files` or the owner's
/// `writeRoots`, and never on a home dotfile, `~/Library` or `VMLAB_HOME`; a read lies under the
/// home, /tmp or `$TMPDIR` and never on a home dotfile, `~/Library` or `VMLAB_HOME` either.
@Suite struct PathPolicyWriteTests {
  /// A fake user home, `$TMPDIR` and outside directory; `VMLAB_HOME` lies inside the fake
  /// `$TMPDIR`, so its refusal is not just a missing root.
  struct Fixture {
    let base: URL
    let home: URL
    let tmpdir: URL
    let vmlab: URL
    let outside: URL

    init() throws {
      base = URL(filePath: PathPolicy.canonical(FileManager.default.temporaryDirectory.path))
        .appending(path: "vmlab-writes-\(UUID().uuidString)")
      home = base.appending(path: "home")
      tmpdir = base.appending(path: "tmpdir")
      vmlab = tmpdir.appending(path: "vmlab")
      outside = base.appending(path: "outside")
      let files = FileManager.default
      for dir in [
        home.appending(path: ".ssh"), home.appending(path: "Library/LaunchAgents"),
        home.appending(path: "project/sub"), tmpdir.appending(path: "sub"), vmlab, outside,
        base.appending(path: "owner"),
      ] {
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
      }
      try files.createSymbolicLink(
        at: tmpdir.appending(path: "to-ssh"), withDestinationURL: home.appending(path: ".ssh"))
      try files.createSymbolicLink(
        at: tmpdir.appending(path: "to-outside"), withDestinationURL: outside)
      try files.createSymbolicLink(
        at: tmpdir.appending(path: "to-project"),
        withDestinationURL: home.appending(path: "project"))
      try files.createSymbolicLink(
        at: tmpdir.appending(path: "inner"), withDestinationURL: tmpdir.appending(path: "sub"))
      try files.createSymbolicLink(
        at: tmpdir.appending(path: "deep"),
        withDestinationURL: home.appending(path: "project/sub"))
      try files.createSymbolicLink(
        atPath: tmpdir.appending(path: "dangling").path,
        withDestinationPath: home.appending(path: ".zshrc-new").path)
    }

    func policy(config: String? = nil) throws -> PathPolicy {
      if let config { try Data(config.utf8).write(to: VMLabConfig.url(home: vmlab)) }
      return PathPolicy.load(home: vmlab, userHome: home, temporaryDirectory: tmpdir)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }
  }

  /// Each row: a path (`H` the home, `T` the temp dir, `V` VMLAB_HOME, `O` outside, `B` the
  /// base), whether a read passes, whether a write passes.
  static let rows: [(String, Bool, Bool)] = [
    ("H/project/a.txt", true, false),
    // The home itself is a directory holding its dotfiles: a read of it is refused.
    ("H", false, false),
    ("H/.zshrc", false, false),
    ("H/.ssh/authorized_keys", false, false),
    ("H/.config/fish/config.fish", false, false),
    ("H/Library/LaunchAgents/x.plist", false, false),
    ("H/LIBRARY/LaunchAgents/x.plist", false, false),
    ("H/library/x", false, false),
    ("H/.SSH/authorized_keys", false, false),
    ("H/vmlab-files/out.txt", true, true),
    ("H/VMLAB-FILES/out.txt", true, true),
    ("H/vmlab-files/.hidden", false, false),
    ("H/project/../.zshrc", false, false),
    ("/tmp/vmlab-write-x", true, true),
    ("/tmp/.vmlab-write-x", true, true),
    ("T/out.log", true, true),
    ("T/sub/new/file", true, true),
    ("T/inner/new.txt", true, true),
    ("V/vms/x/qmp.sock", false, false),
    ("V/VMS/x/disk.raw", false, false),
    ("O/x", false, false),
    ("/etc/x", false, false),
    // Symlinks: the target counts, also for a file that does not exist yet.
    ("T/to-ssh/authorized_keys", false, false),
    ("T/to-outside/x", false, false),
    ("T/to-project/new/file", true, false),
    ("T/dangling", false, false),
    // `..` after a link goes up from its target, as the kernel resolves it: H/.zshrc.
    ("T/deep/../../.zshrc", false, false),
  ]

  func expand(_ path: String, _ f: Fixture) -> String {
    for (letter, url) in [("H", f.home), ("T", f.tmpdir), ("V", f.vmlab), ("O", f.outside)]
    where path == letter || path.hasPrefix(letter + "/") {
      return url.path + path.dropFirst()
    }
    return path
  }

  @Test(arguments: rows) func readsAndWrites(row: (String, Bool, Bool)) throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let policy = try f.policy()
    let path = expand(row.0, f)
    let read = Result { () throws(VMLabError) in try policy.check(path, field: "f") }
    let write = Result { () throws(VMLabError) in
      try policy.check(path, field: "f", access: .write)
    }
    #expect(((try? read.get()) != nil) == row.1, "read \(row.0)")
    #expect(((try? write.get()) != nil) == row.2, "write \(row.0)")
    if case .failure(let error) = write {
      #expect(error.code == .invalidRequest)
      #expect(error.data["field"] == .string("f"))
      #expect(error.data["path"] == .string(path))
      #expect(error.data["access"] == .string("write"))
      #expect(error.data["allowedRoots"]?.arrayValue?.isEmpty == false)
      #expect(error.message.contains(path))
    }
  }

  @Test func vmlabFilesIsCreatedOnDemand() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let files = f.home.appending(path: "vmlab-files")
    let policy = try f.policy()
    _ = try policy.check(files.path + "/x", field: "f")
    #expect(!FileManager.default.fileExists(atPath: files.path))
    _ = try policy.check(files.path + "/x", field: "f", access: .write)
    #expect(FileManager.default.fileExists(atPath: files.path))
  }

  @Test func aRefusalNamesTheRootsAndTheConfigKey() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let error = #expect(throws: VMLabError.self) {
      try f.policy().check(f.home.path + "/project/a.txt", field: "local", access: .write)
    }
    #expect(error?.hint.contains("writeRoots") == true)
    #expect(error?.hint.contains(VMLabConfig.url(home: f.vmlab).path) == true)
    #expect(error?.hint.contains(f.home.path + "/vmlab-files") == true)
    let never = #expect(throws: VMLabError.self) {
      try f.policy().check(f.home.path + "/.zshrc", field: "local", access: .write)
    }
    #expect(never?.data["reason"]?.stringValue?.contains(".zshrc") == true)
  }

  @Test func ownerWriteRootsReplaceVmlabFiles() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let policy = try f.policy(
      config: #"{"writeRoots": ["~/project", "\#(f.base.path)/owner", "relative"]}"#)
    #expect(throws: Never.self) {
      try policy.check(f.home.path + "/project/a.txt", field: "f", access: .write)
    }
    #expect(throws: Never.self) {
      try policy.check(f.base.path + "/owner/x", field: "f", access: .write)
    }
    #expect(throws: Never.self) { try policy.check("/tmp/vmlab-w", field: "f", access: .write) }
    #expect(throws: VMLabError.self) {
      try policy.check(f.home.path + "/vmlab-files/x", field: "f", access: .write)
    }
    // A root the owner lists is still no way to a dotfile.
    #expect(throws: VMLabError.self) {
      try policy.check(f.home.path + "/project/.env", field: "f", access: .write)
    }
    let whole = try f.policy(config: #"{"writeRoots": ["~"]}"#)
    #expect(throws: Never.self) {
      try whole.check(f.home.path + "/project/a.txt", field: "f", access: .write)
    }
    for never in ["/.zshrc", "/.ssh/authorized_keys", "/Library/LaunchAgents/x.plist"] {
      #expect(throws: VMLabError.self) {
        try whole.check(f.home.path + never, field: "f", access: .write)
      }
    }
  }

  @Test func allowAnyPathKeepsTheNeverWrittenList() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let policy = try f.policy(config: #"{"allowAnyPath": true}"#)
    #expect(throws: Never.self) {
      try policy.check(f.outside.path + "/x", field: "f", access: .write)
    }
    #expect(throws: Never.self) {
      try policy.check(f.home.path + "/project/x", field: "f", access: .write)
    }
    for never in [
      f.home.path + "/.zshrc", f.home.path + "/Library/LaunchAgents/x.plist",
      f.vmlab.path + "/vms/x/qmp.sock", f.tmpdir.path + "/to-ssh/authorized_keys",
    ] {
      #expect(throws: VMLabError.self) { try policy.check(never, field: "f", access: .write) }
    }
  }

  @Test func shareHostDirectoryIsAWritePath() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let policy = try f.policy()
    let vmDir = f.vmlab.appending(path: "vms/x")
    for host in [f.home.path, f.home.path + "/Library", f.home.path + "/.ssh"] {
      let error = #expect(throws: VMLabError.self) {
        try SharedDirSpec(host: host).checkHostDirectory(vmDirectory: vmDir, policy: policy)
      }
      #expect(error?.data["field"] == .string("share.host"))
    }
    #expect(throws: Never.self) {
      try SharedDirSpec(host: f.tmpdir.path + "/sub").checkHostDirectory(
        vmDirectory: vmDir, policy: policy)
    }
  }
}

@Suite struct ShareWritePolicyTests {
  /// The real policy: the user's home itself and its Library are no share for a guest to write.
  @Test func aShareAtTheHomeOrItsLibraryIsRefusedAtCreate() async throws {
    let f = try VMManagerTests.Fixture()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for host in [home, home + "/Library", home + "/.ssh"] {
      var draft = VMRecord(
        id: "", name: "shared", profile: .qemuHVF, guest: GuestSpec(os: .linux, arch: .arm64),
        features: [])
      draft.share = SharedDirSpec(host: host, guest: "/mnt/host")
      let error = await #expect(throws: VMLabError.self) {
        try await f.manager.create(draft, plan: f.plan([.sharedDir]))
      }
      #expect(error?.data["field"] == .string("share.host"), "\(host)")
      #expect(error?.data["access"] == .string("write"))
    }
    #expect(try f.store.list().records.isEmpty)
  }
}

/// Reads (the security fix to R-1102): a model-named path vmlab reads, and may hand to a guest,
/// is never a home dotfile or dot-directory, `~/Library` or `VMLAB_HOME`, after every symlink is
/// resolved and whatever its case; `allowAnyPath` does not lift that, the owner's `readRoots` do.
/// A directory is read whole, so nothing in it (followed through symlinks) may be refused.
@Suite struct PathPolicyReadTests {
  typealias Fixture = PathPolicyWriteTests.Fixture

  /// The write fixture plus a few files and trees to read.
  static func fixture() throws -> Fixture {
    let f = try Fixture()
    let files = FileManager.default
    for dir in [
      f.home.appending(path: "project/.git"), f.home.appending(path: ".cache/kernel-builds"),
      f.home.appending(path: ".config"), f.tmpdir.appending(path: "tree/a"),
      f.tmpdir.appending(path: "leaky/a"), f.tmpdir.appending(path: "cycle"),
    ] {
      try files.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    for file in [
      "home/project/a.txt", "home/project/.git/config", "home/.ssh/id_ed25519",
      "home/.cache/kernel-builds/Image", "tmpdir/tree/a/b.txt", "tmpdir/leaky/a/b.txt",
    ] {
      try Data("x".utf8).write(to: f.base.appending(path: file))
    }
    // A tree that reaches ~/.ssh through a link two levels down, and one with a link cycle.
    try files.createSymbolicLink(
      at: f.tmpdir.appending(path: "leaky/a/keys"),
      withDestinationURL: f.home.appending(path: ".ssh"))
    try files.createSymbolicLink(
      at: f.tmpdir.appending(path: "cycle/self"),
      withDestinationURL: f.tmpdir.appending(path: "cycle"))
    try files.createSymbolicLink(
      at: f.tmpdir.appending(path: "to-key"),
      withDestinationURL: f.home.appending(path: ".ssh/id_ed25519"))
    try files.createSymbolicLink(
      at: f.tmpdir.appending(path: "to-builds"),
      withDestinationURL: f.home.appending(path: ".cache/kernel-builds"))
    return f
  }

  /// Each row: a path (`H` home, `T` temp dir, `V` VMLAB_HOME, `O` outside) and whether a read
  /// passes with the default config, with `allowAnyPath`, and with
  /// `readRoots: ["~/.cache/kernel-builds"]`.
  static let rows: [(String, Bool, Bool, Bool)] = [
    ("H/project/a.txt", true, true, true),
    ("H/project", false, false, false),  // holds .git
    ("H/.ssh/id_ed25519", false, false, false),
    ("H/.SSH/ID_ED25519", false, false, false),
    ("H/.zshrc", false, false, false),
    ("H/.netrc", false, false, false),
    ("H/project/.git/config", false, false, false),
    ("H/project/.env", false, false, false),
    ("H/.config/gh/hosts.yml", false, false, false),
    ("H/Library/Keychains/login.keychain-db", false, false, false),
    ("H/library/Application Support/Google/Chrome/Default/Cookies", false, false, false),
    ("H/LIBRARY/x", false, false, false),
    ("H", false, false, false),
    ("H/.cache/kernel-builds/Image", false, false, true),
    ("H/.CACHE/Kernel-Builds/Image", false, false, true),
    ("H/.cache/other", false, false, false),
    ("V/vms/x/id_ed25519", false, false, false),
    ("V/config.json", false, false, false),
    ("T/to-ssh/id_ed25519", false, false, false),
    ("T/to-key", false, false, false),
    ("T/to-builds/Image", false, false, true),
    ("T/tree", true, true, true),
    ("T/tree/a/b.txt", true, true, true),
    ("T/leaky", false, false, false),
    ("T/leaky/a/b.txt", true, true, true),
    ("T/cycle", true, true, true),
    ("O/x", false, true, false),
    ("/etc/hosts", false, true, false),
  ]

  @Test(arguments: rows) func reads(row: (String, Bool, Bool, Bool)) throws {
    let f = try Self.fixture()
    defer { f.cleanUp() }
    let path = PathPolicyWriteTests().expand(row.0, f)
    for (config, expected) in [
      (#"{}"#, row.1), (#"{"allowAnyPath": true}"#, row.2),
      (#"{"readRoots": ["~/.cache/kernel-builds"]}"#, row.3),
    ] {
      let policy = try f.policy(config: config)
      let read = Result { () throws(VMLabError) in try policy.check(path, field: "f") }
      #expect(((try? read.get()) != nil) == expected, "read \(row.0) with \(config)")
      if case .failure(let error) = read {
        #expect(error.code == .invalidRequest)
        #expect(error.data["field"] == .string("f"))
        #expect(error.data["access"] == .string("read"))
        #expect(error.message.contains(path))
      }
    }
  }

  @Test func aRefusalSaysWhyAndNamesReadRoots() throws {
    let f = try Self.fixture()
    defer { f.cleanUp() }
    let policy = try f.policy()
    let link = f.tmpdir.path + "/to-ssh/id_ed25519"
    let error = #expect(throws: VMLabError.self) { try policy.check(link, field: "local") }
    #expect(error?.message.contains(link) == true)
    #expect(error?.message.contains(f.home.path + "/.ssh/id_ed25519") == true)
    #expect(error?.data["reason"]?.stringValue?.contains(".ssh") == true)
    #expect(error?.hint.contains("readRoots") == true)
    #expect(error?.hint.contains(VMLabConfig.url(home: f.vmlab).path) == true)
    let library = #expect(throws: VMLabError.self) {
      try policy.check(f.home.path + "/Library/Keychains/x", field: "kernel")
    }
    #expect(library?.data["reason"]?.stringValue?.contains("Library") == true)
    let tree = #expect(throws: VMLabError.self) {
      try policy.check(f.tmpdir.path + "/leaky", field: "local")
    }
    #expect(tree?.data["reason"]?.stringValue?.contains(".ssh") == true)
  }

  /// A readRoot opens a dot-directory, not VMLAB_HOME around it; one inside VMLAB_HOME opens
  /// only itself.
  @Test func readRootsOpenOnlyWhatTheyList() throws {
    let f = try Self.fixture()
    defer { f.cleanUp() }
    let whole = try f.policy(config: #"{"readRoots": ["~"]}"#)
    #expect(throws: Never.self) { try whole.check(f.home.path + "/.ssh/id_ed25519", field: "f") }
    let outer = try f.policy(config: #"{"readRoots": ["\#(f.tmpdir.path)"]}"#)
    #expect(throws: VMLabError.self) { try outer.check(f.vmlab.path + "/config.json", field: "f") }
    var images = try f.policy()
    images.readRoots.append(PathPolicy.canonical(f.vmlab.path + "/images"))
    #expect(throws: Never.self) { try images.check(f.vmlab.path + "/images/k/vmlinuz", field: "f") }
    #expect(throws: VMLabError.self) { try images.check(f.vmlab.path + "/vms/x/disk", field: "f") }
  }

  /// A hard link is a second name for the same file: it cannot be told from a path, so one in
  /// /tmp to a file in ~/.ssh reads (docs/AGENT.md says so). Only the owner can make one there.
  @Test func aHardLinkIsNotDetectable() throws {
    let f = try Self.fixture()
    defer { f.cleanUp() }
    let link = f.tmpdir.appending(path: "hard")
    try FileManager.default.linkItem(at: f.home.appending(path: ".ssh/id_ed25519"), to: link)
    #expect(throws: Never.self) { try f.policy().check(link.path, field: "f") }
  }
}
