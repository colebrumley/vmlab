import Foundation
import Testing
import VMLabCore

/// `ManifestDiff` over two fixture manifests (R-802 Verify).
@Suite struct ManifestDiffTests {
  static func before() -> GuestManifest {
    GuestManifest(
      id: "m-00000000000a", vm: "vm-m", profile: .macos, roots: ["/opt"],
      files: [
        "/etc/hosts": ManifestFile(kind: .file, size: 10, mode: "0644", mtime: 1, sha256: "aa"),
        "/etc/motd": ManifestFile(kind: .file, size: 5, mode: "0644", mtime: 1, sha256: "bb"),
        "/etc/same": ManifestFile(kind: .file, size: 5, mode: "0644", mtime: 1, sha256: "cc"),
        "/etc/d": ManifestFile(kind: .directory, size: 64, mode: "0755", mtime: 1),
        "/opt/big": ManifestFile(kind: .file, size: 9_000_000, mode: "0644", mtime: 1),
        "/opt/gone": ManifestFile(kind: .file, size: 1, mode: "0600", mtime: 1, sha256: "dd"),
      ],
      packages: ["jq": "1.7.0", "wget": "1.24"],
      services: ["user/com.example.a": "loaded"],
      defaults: [
        "com.apple.dock": ["autohide": "0", "tilesize": "48"],
        "com.example.gone": ["k": "v"],
      ],
      users: ["admin": "uid=501"],
      loginItems: ["login item: Stats"],
      profiles: [])
  }

  static func after() -> GuestManifest {
    var m = before()
    m.id = "m-00000000000b"
    m.files["/etc/hosts"] = ManifestFile(
      kind: .file, size: 12, mode: "0644", mtime: 2, sha256: "ab")
    m.files["/etc/motd"] = ManifestFile(kind: .file, size: 5, mode: "0600", mtime: 2, sha256: "bb")
    m.files["/etc/same"]?.mtime = 9  // mtime alone, with hashes equal: no change
    m.files["/etc/d"] = ManifestFile(kind: .directory, size: 96, mode: "0755", mtime: 2)
    m.files["/opt/big"]?.mtime = 2  // no hash to compare: mtime is the change
    m.files["/opt/gone"] = nil
    m.files["/opt/new"] = ManifestFile(kind: .link, size: 4, mode: "0755", mtime: 2)
    m.packages = ["jq": "1.7.1", "htop": "3.3"]
    m.services["user/com.example.b"] = "loaded"
    m.defaults["com.apple.dock"]?["autohide"] = "1"
    m.defaults["com.example.gone"] = nil
    m.defaults["com.example.new"] = ["x": "1", "y": "2"]
    m.users["guest"] = "uid=201"
    m.loginItems = []
    m.profiles = ["com.example.wifi"]
    return m
  }

  @Test func diffsEverySection() {
    let diff = ManifestDiff(from: Self.before(), to: Self.after())
    #expect(diff.from == "m-00000000000a" && diff.to == "m-00000000000b")
    let files = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })
    #expect(files.count == 5)
    #expect(files["/etc/hosts"]?.change == .changed)
    #expect(
      files["/etc/hosts"]?.changes
        == [
          "size": .init(old: "10", new: "12"), "sha256": .init(old: "aa", new: "ab"),
        ])
    #expect(files["/etc/motd"]?.changes == ["mode": .init(old: "0644", new: "0600")])
    #expect(files["/etc/same"] == nil)
    #expect(files["/etc/d"] == nil)
    #expect(files["/opt/big"]?.changes == ["mtime": .init(old: "1", new: "2")])
    #expect(files["/opt/gone"]?.change == .removed)
    #expect(files["/opt/new"]?.change == .added && files["/opt/new"]?.kind == .link)
    #expect(diff.files.map(\.path) == diff.files.map(\.path).sorted())

    #expect(
      diff.packages == [
        .init(name: "htop", change: .added, old: nil, new: "3.3"),
        .init(name: "jq", change: .changed, old: "1.7.0", new: "1.7.1"),
        .init(name: "wget", change: .removed, old: "1.24", new: nil),
      ])
    #expect(diff.services.map(\.name) == ["user/com.example.b"])
    #expect(diff.users == [.init(name: "guest", change: .added, old: nil, new: "uid=201")])
    #expect(
      diff.loginItems == [.init(name: "login item: Stats", change: .removed, old: nil, new: nil)])
    #expect(diff.profiles.map(\.change) == [.added])

    let dock = diff.defaults.first { $0.domain == "com.apple.dock" }
    #expect(
      dock == .init(domain: "com.apple.dock", key: "autohide", change: .changed, old: "0", new: "1")
    )
    #expect(
      diff.defaults.filter { $0.domain == "com.example.new" }.map(\.change) == [.added, .added])
    #expect(diff.defaults.filter { $0.domain == "com.example.gone" }.map(\.change) == [.removed])
    #expect(diff.counts("defaults") == (added: 2, removed: 1, changed: 1))
    #expect(diff.counts("files") == (added: 1, removed: 1, changed: 3))
    #expect(diff.warnings.isEmpty)
  }

  @Test func identicalManifestsDiffEmpty() {
    let diff = ManifestDiff(from: Self.before(), to: Self.before())
    #expect(diff.isEmpty)
  }

  @Test func differentPathsOrProfilesWarn() {
    var other = Self.after()
    other.roots = ["/srv"]
    other.profile = .custom
    let diff = ManifestDiff(from: Self.before(), to: other)
    #expect(diff.warnings.count == 2)
  }

  @Test func theWholeDiffIsSavedBesideTheManifests() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-md-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = Store(home: home)
    let diff = ManifestDiff(from: Self.before(), to: Self.after())
    let url = try store.saveManifestDiff(diff, vm: "vm-m")
    #expect(url.path.hasSuffix("vms/vm-m/manifests/diff-m-00000000000a-m-00000000000b.json"))
    let read = try JSONDecoder().decode(ManifestDiff.self, from: Data(contentsOf: url))
    #expect(read == diff)
  }
}
