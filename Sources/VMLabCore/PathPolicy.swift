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
  /// Lets `extra.qemuArgs` name options that run host code or pass host hardware through
  /// (`-plugin`, `-semihosting`, `usb-host`, `vfio-*`, ...; `ExtraSpec.hostCodeUses`). Their host
  /// paths still follow the path policy. Only the owner sets it; no tool argument can.
  public var allowHostCode: Bool
  /// The folders a model-named host path may be written in besides `/tmp` and `$TMPDIR`
  /// (`PathPolicy`); nil means vmlab's own `~/vmlab-files`. A leading `~` is the user's home.
  /// Only the owner sets it; no tool argument can.
  public var writeRoots: [String]?

  public init(
    allowAnyPath: Bool = false, ignoreMemoryPressure: Bool = false, allowHostCode: Bool = false,
    writeRoots: [String]? = nil
  ) {
    self.allowAnyPath = allowAnyPath
    self.ignoreMemoryPressure = ignoreMemoryPressure
    self.allowHostCode = allowHostCode
    self.writeRoots = writeRoots
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    allowAnyPath = (try? c.decodeIfPresent(Bool.self, forKey: .allowAnyPath)) ?? false
    ignoreMemoryPressure =
      (try? c.decodeIfPresent(Bool.self, forKey: .ignoreMemoryPressure)) ?? false
    allowHostCode = (try? c.decodeIfPresent(Bool.self, forKey: .allowHostCode)) ?? false
    writeRoots = try? c.decodeIfPresent([String].self, forKey: .writeRoots)
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

/// Where a model-supplied host path may point (R-1102). A path is absolute-only and made
/// canonical (`canonical`: every symlink resolved as the kernel would, `..` after it, a dangling
/// link's target counted), and is then held to the roots of its access:
///
/// - **read** (`vm_file push`, `images register`, `boot`, the inputs of `extra.qemuArgs`): under
///   `roots`, the user's home, `/tmp` and `$TMPDIR`.
/// - **write** (`vm_file pull`'s and `vm_memory_dump`'s `local`, a share's `host` directory, which the guest writes, and
///   the outputs of `extra.qemuArgs`): under `writeRoots`, `/tmp`, `$TMPDIR` and vmlab's own
///   `~/vmlab-files` (created on demand), or instead of that folder the `writeRoots` the owner
///   lists in `VMLAB_HOME/config.json`. Never, even under a write root or with `allowAnyPath`: a
///   dotfile or dot-directory anywhere under the user's home (`~/.zshrc`, `~/.ssh`, `~/.config`),
///   `~/Library` (launch agents), or `VMLAB_HOME` (other VMs' sockets and disks). vmlab's own
///   writes into its VM directories do not come through here.
///
/// `allowAnyPath` in `config.json` lifts the roots for both, not the write refusals. Paths are
/// compared case-insensitively (APFS is). Without `local`, `vm_memory_dump` writes under the
/// VM's own `dumps/`, which does not come through here.
public struct PathPolicy: Sendable, Hashable {
  public enum Access: String, Sendable, Hashable { case read, write }

  public var allowAnyPath: Bool
  /// Canonical directories a read path must be under.
  public var roots: [String]
  /// Canonical folders the owner lists as readable although they are dot-directories.
  public var readRoots: [String] = []
  /// Canonical directories a write path must be under.
  public var writeRoots: [String]
  /// The canonical user home whose dotfiles and `Library` are never written.
  public var userHome: String
  /// The canonical `VMLAB_HOME`, never written; nil when the policy has none.
  public var vmlabHome: String?
  /// vmlab's own write folder (`~/vmlab-files`), created when a write first names it; nil when
  /// the owner listed `writeRoots`.
  public var filesDirectory: String?
  /// Where the owner's config lives, for the hints.
  public var configPath: String?

  /// `writeRoots` defaults to `roots`; `userHome` to this user's home.
  public init(
    allowAnyPath: Bool = false, roots: [String], writeRoots: [String]? = nil,
    userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
    vmlabHome: String? = nil, filesDirectory: String? = nil, configPath: String? = nil
  ) {
    self.allowAnyPath = allowAnyPath
    self.roots = roots.map { Self.canonical($0) }
    self.writeRoots = (writeRoots ?? roots).map { Self.canonical($0) }
    self.userHome = Self.canonical(userHome)
    self.vmlabHome = vmlabHome.map { Self.canonical($0) }
    self.filesDirectory = filesDirectory.map { Self.canonical($0) }
    self.configPath = configPath
  }

  /// The name of vmlab's own write folder in the user's home.
  public static let filesDirectoryName = "vmlab-files"

  /// The policy for `home` (`VMLAB_HOME`): its `config.json`, this user's home and temp dirs.
  public static func load(
    home: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) -> PathPolicy {
    let config = VMLabConfig.load(home: home)
    let files = userHome.appending(path: filesDirectoryName).path
    let listed = config.writeRoots?.compactMap { (entry) -> String? in
      if entry == "~" { return userHome.path }
      if entry.hasPrefix("~/") { return userHome.path + entry.dropFirst() }
      return entry.hasPrefix("/") ? entry : nil
    }
    return PathPolicy(
      allowAnyPath: config.allowAnyPath, roots: [userHome.path, "/tmp", temporaryDirectory.path],
      writeRoots: ["/tmp", temporaryDirectory.path] + (listed ?? [files]),
      userHome: userHome.path, vmlabHome: home.path, filesDirectory: listed == nil ? files : nil,
      configPath: VMLabConfig.url(home: home).path)
  }

  /// The canonical URL of `path`, or `invalid_request` naming `field` when it is relative, lies
  /// outside the roots of `access`, or is a write to a path that is never written.
  public func check(_ path: String, field: String, access: Access = .read) throws(VMLabError)
    -> URL
  {
    guard path.hasPrefix("/") else {
      throw .invalidRequest(
        field: field, reason: "\(path) is not an absolute path",
        hint: "Give the absolute host path, such as /Users/me/file.txt.")
    }
    let resolved = Self.canonical(path)
    let shown = resolved == path ? path : "\(path) (\(resolved))"
    var data: [String: JSONValue] = [
      "field": .string(field), "path": .string(path), "resolved": .string(resolved),
      "access": .string(access.rawValue),
    ]
    switch access {
    case .read:
      if allowAnyPath || roots.contains(where: { Self.contains($0, resolved) }) {
        return URL(filePath: resolved)
      }
      data["allowedRoots"] = .array(roots.map { .string($0) })
      throw VMLabError(
        code: .invalidRequest,
        message: "Invalid request: \(field): \(shown) is outside the user's home and /tmp",
        hint:
          "Use a path under your home directory or /tmp, or set \"allowAnyPath\": true in "
          + "VMLAB_HOME/config.json to lift the restriction.",
        data: data)
    case .write:
      data["allowedRoots"] = .array(writeRoots.map { .string($0) })
      let config = configPath ?? "VMLAB_HOME/config.json"
      let rootList = writeRoots.joined(separator: ", ")
      if let why = neverWritten(resolved) {
        throw VMLabError(
          code: .invalidRequest,
          message: "Invalid request: \(field): \(shown) is never written: \(why)",
          hint:
            "Write under one of \(rootList). Dotfiles in your home, ~/Library and VMLAB_HOME "
            + "are refused even under a write root or with allowAnyPath.",
          data: data.merging(["reason": .string(why)], uniquingKeysWith: { $1 }))
      }
      guard allowAnyPath || writeRoots.contains(where: { Self.contains($0, resolved) }) else {
        throw VMLabError(
          code: .invalidRequest,
          message:
            "Invalid request: \(field): \(shown) is outside the folders vmlab may write "
            + "(\(rootList))",
          hint:
            "Write under one of \(rootList), or have the owner add the folder to "
            + "\"writeRoots\": [...] in \(config).",
          data: data)
      }
      if let files = filesDirectory, Self.contains(files, resolved),
        !FileManager.default.fileExists(atPath: files)
      {
        try? FileManager.default.createDirectory(
          atPath: files, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      }
      return URL(filePath: resolved)
    }
  }

  /// Why the canonical `path` is never written, or nil: it is inside `VMLAB_HOME`, inside
  /// `~/Library`, or a dotfile or dot-directory (or inside one) under the user's home.
  public func neverWritten(_ path: String) -> String? {
    if let vmlabHome, Self.contains(vmlabHome, path) {
      return "it is inside VMLAB_HOME (\(vmlabHome)), which holds every VM's sockets and disks"
    }
    guard Self.contains(userHome, path) else { return nil }
    let rest = path.dropFirst(userHome.count).split(separator: "/")
    if let first = rest.first, Self.fold(String(first)) == "library" {
      return "it is inside ~/Library (launch agents and application settings)"
    }
    if let dot = rest.first(where: { $0.hasPrefix(".") }) {
      return "\(dot) is a dotfile or dot-directory in your home (shell startup files, ~/.ssh, "
        + "~/.config)"
    }
    return nil
  }

  /// Whether `path` is `root` or inside it, compared case- and normalisation-insensitively.
  public static func contains(_ root: String, _ path: String) -> Bool {
    isInside(fold(path), fold(root))
  }

  static func fold(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased()
  }

  static func isInside(_ path: String, _ root: String) -> Bool {
    path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  /// `path` with every symlink resolved, component by component, as the kernel resolves it: a
  /// `..` goes to the parent of what the components before it resolved to, so `/tmp/link/..`
  /// is the link target's parent. A dangling link's target counts (a write would follow it);
  /// the components that do not exist are kept as they are.
  public static func canonical(_ path: String) -> String {
    var resolved: [String] = []
    var pending = Array(path.split(separator: "/").map(String.init).reversed())
    var hops = 0
    while let component = pending.popLast() {
      if component.isEmpty || component == "." { continue }
      if component == ".." {
        if !resolved.isEmpty { resolved.removeLast() }
        continue
      }
      let candidate = "/" + (resolved + [component]).joined(separator: "/")
      if hops < 64,
        let target = try? FileManager.default.destinationOfSymbolicLink(
          atPath: candidate)
      {
        hops += 1
        if target.hasPrefix("/") { resolved = [] }
        pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
        continue
      }
      resolved.append(component)
    }
    return "/" + resolved.joined(separator: "/")
  }
}
