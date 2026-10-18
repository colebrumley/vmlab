import Foundation
import Testing
import VMLabCore

/// The manifest parser over fixture outputs of both profiles (R-801 Verify), the store, and the
/// real script run on this Mac through the stand-in `ssh` of `SSHExecTests`.
@Suite struct ManifestTests {
  static let linuxOutput = """
    @@vmlab manifest 1 Linux
    @@vmlab section files
    directory\t4096\t755\t1760000000\t/etc
    regular file\t7\t644\t1760000001\t/etc/hostname
    regular empty file\t0\t644\t1760000002\t/etc/subgid-
    symbolic link\t21\t777\t1760000003\t/etc/localtime
    regular file\t1024\t640\t1760000004\t/etc/shadow
    regular file\t9000000\t644\t1760000005\t/etc/big.bin
    not a stat line
    @@vmlab section hashes
    0b8a3e8a3a0c63d3a5d0a5b3e0f2a1f97f3e9e1c2b5d4c3b2a19087f6e5d4c3b  /etc/hostname
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  /etc/subgid-
    7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069  /etc/shadow
    \\5f2b3c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b  /etc/we\\nird
    @@vmlab section missing
    /srv/data
    @@vmlab section packages-dpkg
    ii \tbash\t5.2.37-2
    ii \topenssh-server\t1:10.0p1-5
    rc \told-thing\t1.0
    hi \tlinux-image-arm64\t6.12.38-1
    @@vmlab section packages-rpm
    @@vmlab section services-systemd
    ssh.service                    enabled enabled
    systemd-networkd.service       enabled enabled
    getty@.service                 enabled enabled
    @@vmlab section users-passwd
    root:x:0:0:root:/root:/bin/bash
    debian:x:1000:1000:Debian:/home/debian:/bin/bash
    @@vmlab end
    @@vmlab section packages-dpkg
    ii \tafter-the-end\t1
    """

  static let macOutput = """
    @@vmlab manifest 1 Darwin
    @@vmlab section files
    Symbolic Link\t11\t0755\t1760000000\t/etc
    Regular File\t1560\t0644\t1760000001\t/etc/rc.common
    @@vmlab section hashes
    a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90  /etc/rc.common
    @@vmlab section files
    Regular File\t12\t0644\t1760000002\t/Users/admin/.zshrc
    @@vmlab section hashes
    ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  /Users/admin/.zshrc
    @@vmlab section defaults com.apple.dock
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>autohide</key>
    \t<false/>
    \t<key>tilesize</key>
    \t<integer>48</integer>
    \t<key>orientation</key>
    \t<string>bottom</string>
    \t<key>persistent-apps</key>
    \t<array>
    \t\t<dict><key>tile-type</key><string>file-tile</string></dict>
    \t</array>
    \t<key>blob</key>
    \t<data>AAEC</data>
    \t<key>mod</key>
    \t<date>2026-10-18T10:00:00Z</date>
    \t<key>magnification</key>
    \t<real>1.5</real>
    </dict>
    </plist>
    @@vmlab section defaults /Library/Preferences/com.apple.loginwindow
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>GuestEnabled</key><true/></dict></plist>
    @@vmlab section defaults com.example.broken
    <plist><dict><key>
    @@vmlab section defaults com.example.empty
    @@vmlab section packages-brew
    jq 1.7.1
    python@3.13 3.13.1 3.13.2
    @@vmlab section services-launchd user
    PID\tStatus\tLabel
    -\t0\tcom.apple.SafariHistoryServiceAgent
    512\t0\tcom.apple.Finder
    @@vmlab section services-launchd system
    PID\tStatus\tLabel
    1\t0\tcom.apple.xpc.launchd
    @@vmlab section profiles
    _computerlevel[1] attribute: profileIdentifier: com.example.wifi
    There are 1 configuration profiles installed
    @@vmlab section users-dscl
    _www                     70
    admin                    501
    root                     0
    @@vmlab section loginitems
    /Users/admin/Library/LaunchAgents/com.example.agent.plist
    /Library/LaunchDaemons/com.example.daemon.plist
    @@vmlab section loginitems-osascript
    Rectangle, Stats
    @@vmlab end
    """

  @Test func parsesTheLinuxProfile() {
    let m = ManifestParser.parse(
      Self.linuxOutput, id: "m-000000000001", vm: "vm-a", profile: .linux, roots: ["/srv/data"])
    #expect(m.files.count == 6)
    #expect(
      m.files["/etc/hostname"]
        == ManifestFile(
          kind: .file, size: 7, mode: "0644", mtime: 1_760_000_001,
          sha256: "0b8a3e8a3a0c63d3a5d0a5b3e0f2a1f97f3e9e1c2b5d4c3b2a19087f6e5d4c3b"))
    #expect(m.files["/etc"]?.kind == .directory)
    #expect(m.files["/etc"]?.mode == "0755")
    #expect(m.files["/etc/localtime"]?.kind == .link)
    #expect(m.files["/etc/subgid-"]?.kind == .file)
    #expect(m.files["/etc/shadow"]?.mode == "0640")
    #expect(m.files["/etc/shadow"]?.sha256 != nil)
    #expect(m.files["/etc/big.bin"]?.sha256 == nil)
    #expect(
      m.packages == [
        "bash": "5.2.37-2", "openssh-server": "1:10.0p1-5",
        "linux-image-arm64": "6.12.38-1",
      ])
    #expect(m.services["ssh.service"] == "enabled")
    #expect(m.services.count == 3)
    #expect(m.users["debian"] == "uid=1000 gid=1000 home=/home/debian shell=/bin/bash")
    #expect(m.users.count == 2)
    #expect(m.defaults.isEmpty && m.loginItems.isEmpty)
    #expect(m.warnings.contains("/srv/data does not exist in the guest"))
    #expect(m.warnings.contains("1 line(s) of files could not be read"))
    #expect(m.warnings.contains("1 line(s) of hashes could not be read"))
    #expect(m.counts["files"] == 6 && m.counts["packages"] == 3)
  }

  @Test func parsesTheMacOSProfile() {
    let m = ManifestParser.parse(
      Self.macOutput, id: "m-000000000002", vm: "vm-m", profile: .macos, roots: [])
    #expect(m.files["/etc"]?.kind == .link)
    #expect(m.files["/etc/rc.common"]?.sha256?.hasPrefix("a1b2") == true)
    #expect(m.files["/Users/admin/.zshrc"]?.sha256 == String(repeating: "f", count: 64))
    let dock = m.defaults["com.apple.dock"] ?? [:]
    #expect(dock["autohide"] == "0")
    #expect(dock["tilesize"] == "48")
    #expect(dock["orientation"] == "bottom")
    #expect(dock["magnification"] == "1.5")
    #expect(dock["persistent-apps"] == #"[{"tile-type":"file-tile"}]"#)
    #expect(dock["blob"]?.hasPrefix("<3 bytes sha256:") == true)
    #expect(dock["mod"] == "2026-10-18T10:00:00Z")
    #expect(m.defaults["/Library/Preferences/com.apple.loginwindow"] == ["GuestEnabled": "1"])
    #expect(m.defaults["com.example.empty"] == [:])
    #expect(m.defaults["com.example.broken"] == nil)
    #expect(m.warnings.contains("the defaults of com.example.broken could not be read"))
    #expect(m.packages == ["jq": "1.7.1", "python@3.13": "3.13.1 3.13.2"])
    #expect(
      m.services == [
        "user/com.apple.SafariHistoryServiceAgent": "loaded", "user/com.apple.Finder": "loaded",
        "system/com.apple.xpc.launchd": "loaded",
      ])
    #expect(m.profiles == ["com.example.wifi"])
    #expect(m.users == ["_www": "uid=70", "admin": "uid=501", "root": "uid=0"])
    #expect(
      m.loginItems == [
        "/Library/LaunchDaemons/com.example.daemon.plist",
        "/Users/admin/Library/LaunchAgents/com.example.agent.plist",
        "login item: Rectangle", "login item: Stats",
      ])
    #expect(m.counts["defaults"] == 8)
  }

  @Test func nothingAfterTheEndMarkerIsRead() {
    let m = ManifestParser.parse(
      Self.linuxOutput, id: "m-000000000001", vm: "vm-a", profile: .linux, roots: [])
    #expect(m.packages["after-the-end"] == nil)
  }

  @Test func idsAndPaths() throws {
    let id = GuestManifest.newID()
    #expect(GuestManifest.isValidID(id))
    #expect(!GuestManifest.isValidID("m-../../etc"))
    #expect(!GuestManifest.isValidID("cp-000000000000"))
    #expect(throws: VMLabError.self) { try GuestManifests.validate(paths: ["etc"]) }
    #expect(throws: VMLabError.self) { try GuestManifests.validate(paths: ["/a\nb"]) }
    try GuestManifests.validate(paths: ["/etc", "/home/debian"])
    let command = ManifestScript.command(profile: .linux, paths: ["/it's"])
    #expect(command.hasPrefix("sh -c '"))
    #expect(command.hasSuffix(#" vmlab-manifest 'linux' '/it'\''s'"#))
  }

  @Test func storesAndLoadsAManifest() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-mf-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let m = ManifestParser.parse(
      Self.macOutput, id: GuestManifest.newID(), vm: "vm-m", profile: .macos, roots: [],
      createdAt: Date(timeIntervalSince1970: 1_760_000_000))
    let url = try store.saveManifest(m)
    #expect(url.path.hasSuffix("vms/vm-m/manifests/\(m.id).json"))
    #expect(try store.loadManifest(vm: "vm-m", id: m.id) == m)
    let missing = #expect(throws: VMLabError.self) {
      try store.loadManifest(vm: "vm-m", id: "m-ffffffffffff", field: "from")
    }
    #expect(missing?.code == .invalidRequest)
    #expect(missing?.data["field"] == .string("from"))
  }

  /// The real script, profile custom, on this Mac through a stand-in `ssh`: a file's hash, a
  /// directory, a link, a missing root, and a file too big to hash.
  @Test func theScriptRunsOnThisHost() async throws {
    let f = try SSHExecTests.Fixture()
    defer { try? FileManager.default.removeItem(at: f.dir) }
    let root = f.dir.appending(path: "root")
    try FileManager.default.createDirectory(
      at: root.appending(path: "sub"), withIntermediateDirectories: true)
    try "hello\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: root.appending(path: "link").path, withDestinationPath: "a.txt")
    FileManager.default.createFile(
      atPath: root.appending(path: "big").path,
      contents: Data(count: Int(GuestManifest.hashLimit) + 1))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: root.appending(path: "a.txt").path)
    let store = Store(home: f.dir.appending(path: "home"))
    let record = VMRecord(
      id: "vm-t", name: "t", profile: .vzLinux, guest: GuestSpec(os: .linux, arch: .arm64),
      features: [])
    let manifest = try await GuestManifests(store: store).take(
      record, over: f.channel, profile: .custom, paths: [root.path, "/nonexistent-\(UUID())"])
    let real = root.resolvingSymlinksInPath().path
    let prefix = manifest.files.keys.contains(real + "/a.txt") ? real : root.path
    let file = try #require(manifest.files[prefix + "/a.txt"])
    #expect(file.kind == .file && file.size == 6 && file.mode == "0600")
    #expect(file.sha256 == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    #expect(manifest.files[prefix + "/sub"]?.kind == .directory)
    #expect(manifest.files[prefix + "/link"]?.kind == .link)
    #expect(manifest.files[prefix + "/big"]?.sha256 == nil)
    #expect(manifest.files[prefix + "/big"]?.size == GuestManifest.hashLimit + 1)
    #expect(manifest.warnings.contains { $0.hasSuffix("does not exist in the guest") })
    #expect(manifest.packages.isEmpty && manifest.defaults.isEmpty)
    #expect(try store.loadManifest(vm: "vm-t", id: manifest.id) == manifest)
  }
}
