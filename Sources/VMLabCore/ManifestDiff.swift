import Foundation

/// What changed between two guest manifests (R-802), section by section. Every entry says
/// whether it was `added`, `removed` or `changed`; changed entries carry the old and new value
/// (files: of each attribute that changed). Entries are sorted by key, so a diff reads the same
/// every time.
public struct ManifestDiff: Codable, Sendable, Hashable {
  public enum Change: String, Codable, Sendable {
    case added, removed, changed
  }

  /// An attribute's value on both sides.
  public struct Values: Codable, Sendable, Hashable {
    public var old: String?
    public var new: String?

    public init(old: String?, new: String?) {
      self.old = old
      self.new = new
    }
  }

  /// A file, directory or link: `changes` names each attribute that differs (`kind`, `size`,
  /// `mode`, `sha256`; `mtime` only when neither side has a hash to compare).
  public struct FileEntry: Codable, Sendable, Hashable {
    public var path: String
    public var change: Change
    public var kind: ManifestFile.Kind
    public var changes: [String: Values]

    public init(path: String, change: Change, kind: ManifestFile.Kind, changes: [String: Values]) {
      self.path = path
      self.change = change
      self.kind = kind
      self.changes = changes
    }
  }

  /// A keyed entry: a package (value: its version), a service, a user, a login item, a profile.
  public struct Entry: Codable, Sendable, Hashable {
    public var name: String
    public var change: Change
    public var old: String?
    public var new: String?

    public init(name: String, change: Change, old: String?, new: String?) {
      self.name = name
      self.change = change
      self.old = old
      self.new = new
    }
  }

  /// One key of one defaults domain.
  public struct DefaultsEntry: Codable, Sendable, Hashable {
    public var domain: String
    public var key: String
    public var change: Change
    public var old: String?
    public var new: String?

    public init(domain: String, key: String, change: Change, old: String?, new: String?) {
      self.domain = domain
      self.key = key
      self.change = change
      self.old = old
      self.new = new
    }
  }

  /// The section names, in the order results list them.
  public static let sections = [
    "files", "packages", "services", "defaults", "users", "loginItems", "profiles",
  ]

  public var from: String
  public var to: String
  public var files: [FileEntry]
  public var packages: [Entry]
  public var services: [Entry]
  public var defaults: [DefaultsEntry]
  public var users: [Entry]
  public var loginItems: [Entry]
  public var profiles: [Entry]
  public var warnings: [String]

  /// The changes from `old` to `new`.
  public init(from old: GuestManifest, to new: GuestManifest) {
    from = old.id
    to = new.id
    files = Self.files(old.files, new.files)
    packages = Self.entries(old.packages, new.packages)
    services = Self.entries(old.services, new.services)
    users = Self.entries(old.users, new.users)
    loginItems = Self.entries(Self.set(old.loginItems), Self.set(new.loginItems))
    profiles = Self.entries(Self.set(old.profiles), Self.set(new.profiles))
    defaults = []
    for domain in Set(old.defaults.keys).union(new.defaults.keys).sorted() {
      let before = old.defaults[domain] ?? [:]
      let after = new.defaults[domain] ?? [:]
      for entry in Self.entries(before, after) {
        defaults.append(
          DefaultsEntry(
            domain: domain, key: entry.name, change: entry.change, old: entry.old,
            new: entry.new))
      }
    }
    warnings = []
    if old.profile != new.profile {
      warnings.append(
        "the manifests have different profiles (\(old.profile.rawValue), "
          + "\(new.profile.rawValue)); sections only one of them records show as added or removed")
    }
    if Set(old.roots) != Set(new.roots) {
      warnings.append(
        "the manifests walked different paths (\(old.roots.joined(separator: ", ")); "
          + "\(new.roots.joined(separator: ", "))); files outside the shared ones show as added "
          + "or removed")
    }
  }

  /// Entries per section that are added, removed and changed.
  public func counts(_ section: String) -> (added: Int, removed: Int, changed: Int) {
    let changes: [Change]
    switch section {
    case "files": changes = files.map(\.change)
    case "packages": changes = packages.map(\.change)
    case "services": changes = services.map(\.change)
    case "defaults": changes = defaults.map(\.change)
    case "users": changes = users.map(\.change)
    case "loginItems": changes = loginItems.map(\.change)
    case "profiles": changes = profiles.map(\.change)
    default: changes = []
    }
    return (
      changes.filter { $0 == .added }.count, changes.filter { $0 == .removed }.count,
      changes.filter { $0 == .changed }.count
    )
  }

  public var isEmpty: Bool {
    files.isEmpty && packages.isEmpty && services.isEmpty && defaults.isEmpty && users.isEmpty
      && loginItems.isEmpty && profiles.isEmpty
  }

  // MARK: Helpers

  static func set(_ items: [String]) -> [String: String] {
    Dictionary(items.map { ($0, "") }, uniquingKeysWith: { a, _ in a })
  }

  static func entries(_ old: [String: String], _ new: [String: String]) -> [Entry] {
    var result: [Entry] = []
    for key in Set(old.keys).union(new.keys).sorted() {
      switch (old[key], new[key]) {
      case (nil, let value?):
        result.append(Entry(name: key, change: .added, old: nil, new: value.nilIfEmpty))
      case (let value?, nil):
        result.append(Entry(name: key, change: .removed, old: value.nilIfEmpty, new: nil))
      case (let a?, let b?) where a != b:
        result.append(Entry(name: key, change: .changed, old: a, new: b))
      default: continue
      }
    }
    return result
  }

  static func files(_ old: [String: ManifestFile], _ new: [String: ManifestFile]) -> [FileEntry] {
    var result: [FileEntry] = []
    for path in Set(old.keys).union(new.keys).sorted() {
      switch (old[path], new[path]) {
      case (nil, let file?):
        result.append(FileEntry(path: path, change: .added, kind: file.kind, changes: [:]))
      case (let file?, nil):
        result.append(FileEntry(path: path, change: .removed, kind: file.kind, changes: [:]))
      case (let a?, let b?):
        let changes = attributes(a, b)
        if !changes.isEmpty {
          result.append(FileEntry(path: path, change: .changed, kind: b.kind, changes: changes))
        }
      default: continue
      }
    }
    return result
  }

  /// What differs between two states of one path. A directory's size is how its entries are
  /// stored, so it is not compared; mtime counts only for files neither side could hash.
  static func attributes(_ a: ManifestFile, _ b: ManifestFile) -> [String: Values] {
    var changes: [String: Values] = [:]
    if a.kind != b.kind { changes["kind"] = Values(old: a.kind.rawValue, new: b.kind.rawValue) }
    if a.mode != b.mode { changes["mode"] = Values(old: a.mode, new: b.mode) }
    if a.size != b.size, a.kind != .directory || b.kind != .directory {
      changes["size"] = Values(old: String(a.size), new: String(b.size))
    }
    if a.sha256 != b.sha256, a.sha256 != nil || b.sha256 != nil {
      changes["sha256"] = Values(old: a.sha256, new: b.sha256)
    }
    if a.kind == .file, b.kind == .file, a.sha256 == nil, b.sha256 == nil, a.mtime != b.mtime {
      changes["mtime"] = Values(old: String(a.mtime), new: String(b.mtime))
    }
    return changes
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Store

extension Store {
  /// `<vm>/manifests/diff-<from>-<to>.json`, beside the manifests.
  public func manifestDiffURL(of vm: String, from: String, to: String) -> URL {
    manifestsDirectory(of: vm).appending(path: "diff-\(from)-\(to).json")
  }

  /// Writes the whole of `diff` beside the manifests of `vm` and returns the path.
  @discardableResult
  public func saveManifestDiff(_ diff: ManifestDiff, vm: String) throws(VMLabError) -> URL {
    let url = manifestDiffURL(of: vm, from: diff.from, to: diff.to)
    try writeJSON(diff, to: url, what: "manifest diff")
    return url
  }
}
