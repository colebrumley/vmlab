import Foundation

/// `VMLAB_HOME/config.json` (Appendix F). Only the keys a build reads are decoded; unknown keys
/// are ignored, and a missing or malformed file means the defaults (the safe ones).
public struct VMLabConfig: Codable, Sendable, Hashable {
  /// Lets host paths given to tools lie anywhere, not only under the user's home or `/tmp`
  /// (R-1102).
  public var allowAnyPath: Bool
  /// Lets a guest start although the host is under memory pressure or short of available memory
  /// (the owner's escape hatch; `VMLAB_IGNORE_MEMORY_PRESSURE=1` does the same).
  public var ignoreMemoryPressure: Bool

  public init(allowAnyPath: Bool = false, ignoreMemoryPressure: Bool = false) {
    self.allowAnyPath = allowAnyPath
    self.ignoreMemoryPressure = ignoreMemoryPressure
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    allowAnyPath = (try? c.decodeIfPresent(Bool.self, forKey: .allowAnyPath)) ?? false
    ignoreMemoryPressure =
      (try? c.decodeIfPresent(Bool.self, forKey: .ignoreMemoryPressure)) ?? false
  }

  public static func url(home: URL) -> URL { home.appending(path: "config.json") }

  /// The config under `home`, or the defaults when there is none or it does not parse.
  public static func load(home: URL) -> VMLabConfig {
    guard let data = try? Data(contentsOf: url(home: home)),
      let config = try? JSONDecoder().decode(VMLabConfig.self, from: data)
    else { return VMLabConfig() }
    return config
  }
}

/// Where a model-supplied host path may point (R-1102): `vm_file`'s `local`, `images register`'s
/// `path`, `kernel` and `initrd`, a share's `host` directory and a request's `boot` images. A path is made absolute-only,
/// standardised and canonicalised (every symlink of its longest existing prefix resolved, so
/// `..`, `/tmp` → `/private/tmp` and a link out of the home cannot slip past), and must then lie
/// under one of `roots`: the user's home, `/tmp`, and the user's temporary directory (`$TMPDIR`,
/// the per-user `/tmp` on macOS), unless `allowAnyPath` is set in `VMLAB_HOME/config.json`.
/// `vm_memory_dump` takes no host path; it writes under the VM's own `dumps/`.
public struct PathPolicy: Sendable, Hashable {
  public var allowAnyPath: Bool
  /// Canonical directories a path must be under.
  public var roots: [String]

  public init(allowAnyPath: Bool = false, roots: [String]) {
    self.allowAnyPath = allowAnyPath
    self.roots = roots.map { Self.canonical($0) }
  }

  /// The policy for `home` (`VMLAB_HOME`): its `config.json` and this user's home and temp dirs.
  public static func load(
    home: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) -> PathPolicy {
    PathPolicy(
      allowAnyPath: VMLabConfig.load(home: home).allowAnyPath,
      roots: [userHome.path, "/tmp", temporaryDirectory.path])
  }

  /// The canonical URL of `path`, or `invalid_request` naming `field` when it is relative or
  /// lies outside the roots.
  public func check(_ path: String, field: String) throws(VMLabError) -> URL {
    guard path.hasPrefix("/") else {
      throw .invalidRequest(
        field: field, reason: "\(path) is not an absolute path",
        hint: "Give the absolute host path, such as /Users/me/file.txt.")
    }
    let resolved = Self.canonical(path)
    if allowAnyPath || roots.contains(where: { Self.isInside(resolved, $0) }) {
      return URL(filePath: resolved)
    }
    let shown = resolved == path ? path : "\(path) (\(resolved))"
    throw VMLabError(
      code: .invalidRequest,
      message: "Invalid request: \(field): \(shown) is outside the user's home and /tmp",
      hint:
        "Use a path under your home directory or /tmp, or set \"allowAnyPath\": true in "
        + "VMLAB_HOME/config.json to lift the restriction.",
      data: [
        "field": .string(field), "path": .string(path), "resolved": .string(resolved),
        "allowedRoots": .array(roots.map { .string($0) }),
      ])
  }

  static func isInside(_ path: String, _ root: String) -> Bool {
    path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  /// `path` standardised (`.` and `..` removed) with the symlinks of its longest existing prefix
  /// resolved by `realpath(3)`; the components that do not exist yet are appended as they are.
  public static func canonical(_ path: String) -> String { canonical(path, depth: 0) }

  private static func canonical(_ path: String, depth: Int) -> String {
    let standard = URL(filePath: path).standardizedFileURL.path
    var head = standard
    var tail: [String] = []
    while true {
      if let real = realpath(head, nil) {
        defer { free(real) }
        var result = String(cString: real)
        for component in tail.reversed() {
          result = result == "/" ? "/" + component : result + "/" + component
        }
        return result
      }
      guard head != "/", !head.isEmpty else { return standard }
      let url = URL(filePath: head)
      // A dangling symlink: realpath fails, but writing through it would follow it.
      if depth < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: head) {
        let base =
          target.hasPrefix("/") ? target : url.deletingLastPathComponent().path + "/" + target
        let rest = tail.reversed().joined(separator: "/")
        return canonical(rest.isEmpty ? base : base + "/" + rest, depth: depth + 1)
      }
      tail.append(url.lastPathComponent)
      head = url.deletingLastPathComponent().path
      if head.hasSuffix("/"), head.count > 1 { head.removeLast() }
    }
  }
}
