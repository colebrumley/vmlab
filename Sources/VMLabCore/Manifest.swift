import CryptoKit
import Foundation

/// What a guest manifest records besides the files under its roots (R-801): `linux` adds
/// packages, enabled services, users and `/etc`; `macos` adds defaults domains, Homebrew
/// packages, launchd jobs, configuration profiles, users, login items, `/etc` and the home
/// directory's dotfiles; `custom` records only the roots.
public enum ManifestProfile: String, CaseIterable, Codable, Sendable {
  case linux, macos, custom

  /// The profile that matches the guest's OS.
  public init(os: GuestSpec.OS) {
    self = os == .macos ? .macos : .linux
  }
}

/// One file, directory or link under a manifest's roots. `mode` is the octal permission bits
/// (`0644`); `sha256` is present for regular files of at most `GuestManifest.hashLimit` bytes
/// that the script could read.
public struct ManifestFile: Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable {
    case file, directory, link, other
  }

  public var kind: Kind
  public var size: Int64
  public var mode: String
  public var mtime: Int
  public var sha256: String?

  public init(kind: Kind, size: Int64, mode: String, mtime: Int, sha256: String? = nil) {
    self.kind = kind
    self.size = size
    self.mode = mode
    self.mtime = mtime
    self.sha256 = sha256
  }
}

/// A record of what is in a guest at one moment (R-801), stored at `<vm>/manifests/<id>.json`.
/// Maps are keyed by what identifies an entry (a path, a package, a unit, a user), so two
/// manifests diff key by key (R-802). `defaults` is domain → key → the value as text: booleans
/// as `0`/`1` (as `defaults read` prints them), numbers and strings as they are, dates in ISO
/// 8601, data as its length and hash prefix, arrays and dictionaries as compact JSON.
public struct GuestManifest: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1
  /// Files larger than this are listed without a hash (8 MB).
  public static let hashLimit: Int64 = 8 * 1024 * 1024

  public var schemaVersion: Int
  public var id: String
  public var vm: String
  public var profile: ManifestProfile
  public var createdAt: Date
  /// The roots the caller asked for (the profile's own, such as `/etc`, are implied by it).
  public var roots: [String]
  /// The checkpoint this manifest was taken for, if any.
  public var checkpoint: String?
  public var files: [String: ManifestFile]
  public var packages: [String: String]
  public var services: [String: String]
  public var defaults: [String: [String: String]]
  public var users: [String: String]
  public var loginItems: [String]
  public var profiles: [String]
  /// What the script could not record (a missing tool, lines it could not read).
  public var warnings: [String]

  public init(
    id: String, vm: String, profile: ManifestProfile, createdAt: Date = Date(),
    roots: [String] = [], checkpoint: String? = nil, files: [String: ManifestFile] = [:],
    packages: [String: String] = [:], services: [String: String] = [:],
    defaults: [String: [String: String]] = [:], users: [String: String] = [:],
    loginItems: [String] = [], profiles: [String] = [], warnings: [String] = []
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.vm = vm
    self.profile = profile
    // Whole seconds, as the ISO 8601 file keeps them, so a manifest reads back equal.
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    self.roots = roots
    self.checkpoint = checkpoint
    self.files = files
    self.packages = packages
    self.services = services
    self.defaults = defaults
    self.users = users
    self.loginItems = loginItems
    self.profiles = profiles
    self.warnings = warnings
  }

  /// Entries per section, as `vm_manifest` returns them. `defaults` counts keys.
  public var counts: [String: Int] {
    [
      "files": files.count, "packages": packages.count, "services": services.count,
      "defaults": defaults.values.reduce(0) { $0 + $1.count }, "users": users.count,
      "loginItems": loginItems.count, "profiles": profiles.count,
    ]
  }

  /// `m-` and twelve hex digits.
  public static func newID() -> String {
    "m-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
  }

  /// Whether `id` has the shape `newID()` makes, so it is safe as a file name.
  public static func isValidID(_ id: String) -> Bool {
    guard id.hasPrefix("m-"), id.count == 14 else { return false }
    return id.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }
}

// MARK: - Store

extension Store {
  /// `<vm>/manifests/`.
  public func manifestsDirectory(of vm: String) -> URL {
    directory(of: vm).appending(path: "manifests")
  }

  public func manifestURL(of vm: String, id: String) -> URL {
    manifestsDirectory(of: vm).appending(path: "\(id).json")
  }

  /// Writes `manifest` under its VM's directory and returns the path.
  @discardableResult
  public func saveManifest(_ manifest: GuestManifest) throws(VMLabError) -> URL {
    let url = manifestURL(of: manifest.vm, id: manifest.id)
    try writeJSON(manifest, to: url, what: "manifest \(manifest.id)")
    return url
  }

  /// The stored manifest `id` of `vm`: `invalid_request` (field `field`) when there is none.
  public func loadManifest(vm: String, id: String, field: String = "id") throws(VMLabError)
    -> GuestManifest
  {
    guard GuestManifest.isValidID(id) else {
      throw VMLabError.invalidRequest(
        field: field, reason: "\(id) is not a manifest id",
        hint: "Use the id vm_manifest returned (m- and twelve hex digits).")
    }
    return try loadManifest(at: manifestURL(of: vm, id: id), field: field)
  }

  /// The manifest stored at `url`.
  public func loadManifest(at url: URL, field: String = "id") throws(VMLabError) -> GuestManifest {
    guard let data = try? Data(contentsOf: url) else {
      throw VMLabError.invalidRequest(
        field: field, reason: "no manifest at \(url.path)",
        hint: "Take one with vm_manifest, or create a checkpoint with manifest: true.")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(GuestManifest.self, from: data)
    } catch {
      throw VMLabError(
        code: .internal, message: "The manifest at \(url.path) is unreadable: \(error)",
        hint: "Take a new manifest; this one may have been written by a newer vmlab.",
        data: ["id": .string(UUID().uuidString.lowercased()), "path": .string(url.path)])
    }
  }

  /// Encodes `value` (sorted keys, ISO 8601 dates) and writes it atomically to `url`.
  func writeJSON(_ value: some Encodable, to url: URL, what: String) throws(VMLabError) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(value).write(to: url, options: .atomic)
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot write the \(what) to \(url.path): \(error)",
        hint: "Check that the VM directory is writable.",
        data: ["id": .string(UUID().uuidString.lowercased()), "path": .string(url.path)])
    }
  }
}

// MARK: - Taking

/// Takes guest manifests over a VM's exec channel (R-801): one POSIX `sh` script, passed as an
/// argument so nothing it runs can read it from stdin, prints each section between marker lines
/// in the plain format of the tool that produced it; `ManifestParser` turns that into a
/// `GuestManifest`. The script uses `sudo -n` for the file walks and system queries when the
/// login user may, so root-only files under `/etc` get hashes too.
public struct GuestManifests: Sendable {
  /// How long the script may run (a large root on a slow guest takes minutes).
  public static let timeout: Duration = .seconds(900)

  public var store: Store

  public init(store: Store) { self.store = store }

  /// Checks the roots: absolute paths without newlines.
  public static func validate(paths: [String], field: String = "paths") throws(VMLabError) {
    for path in paths {
      guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0") else {
        throw VMLabError.invalidRequest(
          field: field, reason: "\(path) is not an absolute guest path",
          hint: "Pass absolute paths such as /etc or /home/debian.")
      }
    }
  }

  /// `wrong_state` unless `record` is running: a manifest runs commands in the guest.
  public static func requireRunning(_ record: VMRecord) throws(VMLabError) {
    guard record.state != .running else { return }
    let legal = Lifecycle.legalActions(in: record.state).map(\.rawValue)
    throw VMLabError(
      code: .wrongState,
      message: "VM \(record.id) is \(record.state.rawValue); a manifest needs it running",
      hint: record.state == .paused
        ? "Resume it with vm_lifecycle resume." : "Start it with vm_lifecycle start.",
      data: [
        "vm": .string(record.id), "state": .string(record.state.rawValue),
        "legalActions": .array(legal.map { .string($0) }),
      ])
  }

  /// The channel a manifest runs over: SSH when the plan granted it, else the plan's exec channel
  /// (`capability_missing` when it granted neither).
  public static func channel(of vm: any RunningVM) throws(VMLabError) -> any ExecChannel {
    vm.features.contains(.execSSH) ? try vm.channel(.execSSH) : try vm.channel(.exec)
  }

  /// Runs the script for `profile` over `channel`, parses the output and stores the manifest of
  /// `record` under `<vm>/manifests/`. `engine_error` when the script did not run to its end.
  public func take(
    _ record: VMRecord, over channel: any ExecChannel, profile: ManifestProfile,
    paths: [String], checkpoint: String? = nil
  ) async throws(VMLabError) -> GuestManifest {
    try Self.validate(paths: paths)
    let result = try await channel.run(
      ExecRequest(
        command: ManifestScript.command(profile: profile, paths: paths),
        timeout: Self.timeout))
    var output = result.stdout
    if result.truncated, let log = result.logPath {
      // The whole output is in the log; the inline text is only its head and tail.
      if let data = FileManager.default.contents(atPath: log) {
        output = String(decoding: data, as: UTF8.self)
      }
      try? FileManager.default.removeItem(atPath: log)
    }
    guard ManifestScript.finished(output) else {
      let stderr = String(result.stderr.suffix(2000))
      throw VMLabError(
        code: .engineError,
        message:
          "The manifest script did not finish in \(record.id) (exit \(result.exitCode))",
        hint: "Check that the guest has /bin/sh and that vm_exec works; stderr is in data.",
        data: [
          "engine": .string("guest"), "raw": .string(stderr),
          "exitCode": .number(Double(result.exitCode)),
        ])
    }
    var manifest = ManifestParser.parse(
      output, id: GuestManifest.newID(), vm: record.id, profile: profile, roots: paths)
    manifest.checkpoint = checkpoint
    try store.saveManifest(manifest)
    return manifest
  }
}

/// The manifests `vm_checkpoint create manifest: true` takes (R-800's hook): the guest's own
/// profile, no extra roots, over the VM's exec channel. Returns the stored manifest's path.
public struct CheckpointManifests: GuestManifestTaker {
  public var store: Store
  public var backends: BackendRegistry

  public init(store: Store, backends: BackendRegistry) {
    self.store = store
    self.backends = backends
  }

  public func take(_ record: VMRecord, checkpoint: String) async throws(VMLabError) -> String {
    try GuestManifests.requireRunning(record)
    let vm = try await backends.backend(for: record.profile).attach(record)
    let manifest = try await GuestManifests(store: store).take(
      record, over: try GuestManifests.channel(of: vm),
      profile: ManifestProfile(os: record.guest.os),
      paths: [], checkpoint: checkpoint)
    return store.manifestURL(of: record.id, id: manifest.id).path
  }
}

// MARK: - Script

/// The shell text of a manifest. Every section starts with `@@vmlab section <name>` and holds
/// the raw output of one command; the last line is `@@vmlab end`.
public enum ManifestScript {
  public static let marker = "@@vmlab "
  public static let endMarker = "@@vmlab end"

  /// Whether `output` has the end marker on a line of its own: the script ran to its end.
  public static func finished(_ output: String) -> Bool {
    output.split(separator: "\n").contains { $0 == endMarker || $0 == endMarker + "\r" }
  }

  /// `sh -c <script> vmlab-manifest <profile> <paths...>`, every word single-quoted.
  public static func command(profile: ManifestProfile, paths: [String]) -> String {
    (["sh", "-c", RemoteShell.quote(script), "vmlab-manifest", RemoteShell.quote(profile.rawValue)]
      + paths.map(RemoteShell.quote)).joined(separator: " ")
  }

  /// `$1` is the profile, the rest are the roots. Every probe's stderr is discarded, so the only
  /// stderr is the shell's own.
  public static let script = #"""
    exec </dev/null
    profile=$1
    shift
    os=$(uname -s)
    S=""
    if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      S="sudo -n"
    fi
    sec() { echo "@@vmlab section $*"; }
    walk() {
      if [ "$os" = Darwin ]; then
        $S find -H "$@" -exec stat -f '%HT%t%z%t%Mp%Lp%t%m%t%N' {} + 2>/dev/null
      else
        $S find -H "$@" -exec stat --printf '%F\t%s\t%a\t%Y\t%n\n' {} + 2>/dev/null
      fi
    }
    hashes() {
      if [ "$os" = Darwin ]; then
        $S find -H "$@" -type f -size -8388609c -exec shasum -a 256 {} + 2>/dev/null
      else
        $S find -H "$@" -type f -size -8388609c -exec sha256sum {} + 2>/dev/null
      fi
    }
    tree() {
      sec files
      walk "$@"
      sec hashes
      hashes "$@"
    }
    echo "@@vmlab manifest 1 $os"
    for root in "$@"; do
      [ -e "$root" ] || { sec missing; echo "$root"; continue; }
      tree "$root" -xdev
    done
    if [ "$profile" = linux ]; then
      tree /etc -xdev
      sec packages-dpkg
      command -v dpkg-query >/dev/null 2>&1 &&
        dpkg-query -W -f '${db:Status-Abbrev}\t${Package}\t${Version}\n' 2>/dev/null
      sec packages-rpm
      command -v rpm >/dev/null 2>&1 &&
        rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null
      sec services-systemd
      command -v systemctl >/dev/null 2>&1 &&
        systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null
      sec users-passwd
      getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null
    fi
    if [ "$profile" = macos ]; then
      tree /etc -xdev
      tree "$HOME" -maxdepth 1 -name '.*' -type f
      for f in "$HOME"/Library/Preferences/*.plist; do
        [ -f "$f" ] || continue
        d=$(basename "$f" .plist)
        sec defaults "$d"
        defaults export "$d" - 2>/dev/null || plutil -convert xml1 -o - "$f" 2>/dev/null
      done
      for f in /Library/Preferences/*.plist; do
        [ -f "$f" ] || continue
        d=/Library/Preferences/$(basename "$f" .plist)
        sec defaults "$d"
        defaults export "$d" - 2>/dev/null || plutil -convert xml1 -o - "$f" 2>/dev/null
      done
      sec packages-brew
      for b in brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if command -v "$b" >/dev/null 2>&1; then
          "$b" list --versions 2>/dev/null
          break
        fi
      done
      sec services-launchd user
      launchctl list 2>/dev/null
      if [ -n "$S" ] || [ "$(id -u)" = 0 ]; then
        sec services-launchd system
        $S launchctl list 2>/dev/null
      fi
      sec profiles
      $S profiles list 2>/dev/null
      sec users-dscl
      dscl . -list /Users UniqueID 2>/dev/null
      sec loginitems
      for f in "$HOME"/Library/LaunchAgents/*.plist /Library/LaunchAgents/*.plist \
        /Library/LaunchDaemons/*.plist; do
        [ -e "$f" ] && echo "$f"
      done
      sec loginitems-osascript
      # The watchdog's "Terminated" notice goes to the group's stderr, which is discarded.
      t=$(mktemp 2>/dev/null) && {
        osascript -e 'tell application "System Events" to get the name of every login item' \
          >"$t" 2>/dev/null &
        p=$!
        (sleep 10; kill "$p") >/dev/null 2>&1 &
        w=$!
        wait "$p" 2>/dev/null
        kill "$w" 2>/dev/null
        cat "$t"
        rm -f "$t"
      } 2>/dev/null
    fi
    echo "@@vmlab end"
    """#
}

// MARK: - Parser

/// Turns the script's output into a `GuestManifest`. Each section is read in the format of the
/// command that wrote it; lines it cannot read are counted in a warning, never fatal.
public enum ManifestParser {
  public static func parse(
    _ output: String, id: String, vm: String, profile: ManifestProfile, roots: [String],
    createdAt: Date = Date()
  ) -> GuestManifest {
    var manifest = GuestManifest(
      id: id, vm: vm, profile: profile, createdAt: createdAt, roots: roots)
    var hashes: [String: String] = [:]
    var skipped: [String: Int] = [:]
    for (header, lines) in sections(of: output) {
      let words = header.split(separator: " ", maxSplits: 1).map(String.init)
      let name = words.first ?? ""
      let argument = words.count > 1 ? words[1] : ""
      var bad = 0
      switch name {
      case "files":
        for line in lines {
          guard let (path, file) = file(line) else {
            bad += 1
            continue
          }
          manifest.files[path] = file
        }
      case "hashes":
        for line in lines {
          guard let (path, hash) = hash(line) else {
            bad += 1
            continue
          }
          hashes[path] = hash
        }
      case "missing":
        for line in lines { manifest.warnings.append("\(line) does not exist in the guest") }
      case "packages-dpkg":
        for line in lines {
          let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
          guard f.count >= 3 else {
            bad += 1
            continue
          }
          // `ii` installed, `hi` held; `rc` and the like are gone but for their config files.
          if f[0].count >= 2, f[0].dropFirst().first == "i" { manifest.packages[f[1]] = f[2] }
        }
      case "packages-rpm":
        for line in lines {
          let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
          guard f.count >= 2 else {
            bad += 1
            continue
          }
          manifest.packages[f[0]] = f[1]
        }
      case "packages-brew":
        for line in lines {
          let f = line.split(separator: " ").map(String.init)
          guard f.count >= 2 else {
            bad += 1
            continue
          }
          manifest.packages[f[0]] = f.dropFirst().joined(separator: " ")
        }
      case "services-systemd":
        for line in lines {
          let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
          guard f.count >= 2 else {
            bad += 1
            continue
          }
          manifest.services[f[0]] = f[1]
        }
      case "services-launchd":
        // PID, last exit status, label. Only the label is kept: PIDs and statuses churn.
        let domain = argument.isEmpty ? "user" : argument
        for line in lines {
          let f = line.split(separator: "\t").map(String.init)
          guard f.count >= 3 else {
            bad += 1
            continue
          }
          if f[0] == "PID" { continue }
          manifest.services["\(domain)/\(f[2])"] = "loaded"
        }
      case "users-passwd":
        for line in lines {
          let f = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
          guard f.count >= 7 else {
            bad += 1
            continue
          }
          manifest.users[f[0]] = "uid=\(f[2]) gid=\(f[3]) home=\(f[5]) shell=\(f[6])"
        }
      case "users-dscl":
        for line in lines {
          let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
          guard f.count >= 2 else {
            bad += 1
            continue
          }
          manifest.users[f[0]] = "uid=\(f[f.count - 1])"
        }
      case "defaults":
        guard !argument.isEmpty else { continue }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else {
          manifest.defaults[argument] = [:]
          continue
        }
        guard let values = defaults(text) else {
          manifest.warnings.append("the defaults of \(argument) could not be read")
          continue
        }
        manifest.defaults[argument] = values
      case "profiles":
        for line in lines {
          guard let range = line.range(of: "profileIdentifier: ") else { continue }
          let identifier = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
          if !identifier.isEmpty { manifest.profiles.append(identifier) }
        }
      case "loginitems":
        manifest.loginItems += lines
      case "loginitems-osascript":
        for line in lines {
          for name in line.split(separator: ",") {
            let name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { manifest.loginItems.append("login item: \(name)") }
          }
        }
      default:
        continue
      }
      if bad > 0 { skipped[name, default: 0] += bad }
    }
    for (path, hash) in hashes where manifest.files[path] != nil {
      manifest.files[path]?.sha256 = hash
    }
    manifest.loginItems = Array(Set(manifest.loginItems)).sorted()
    manifest.profiles = Array(Set(manifest.profiles)).sorted()
    for (section, count) in skipped.sorted(by: { $0.key < $1.key }) {
      manifest.warnings.append("\(count) line(s) of \(section) could not be read")
    }
    return manifest
  }

  /// The sections in order: the header after `@@vmlab section ` and the non-empty lines up to
  /// the next marker. Nothing after `@@vmlab end` is read.
  static func sections(of output: String) -> [(String, [String])] {
    var result: [(String, [String])] = []
    var header: String?
    var lines: [String] = []
    let prefix = ManifestScript.marker + "section "
    for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
      if line.hasPrefix(ManifestScript.marker) {
        if let header { result.append((header, lines)) }
        header = nil
        lines = []
        if line == ManifestScript.endMarker { break }
        if line.hasPrefix(prefix) { header = String(line.dropFirst(prefix.count)) }
        continue
      }
      if header != nil, !line.isEmpty { lines.append(line) }
    }
    if let header { result.append((header, lines)) }
    return result
  }

  /// A `stat` line: type, size, octal mode, mtime and path, tab-separated (GNU `%F` or BSD `%HT`
  /// type names).
  static func file(_ line: String) -> (String, ManifestFile)? {
    let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(
      String.init)
    guard f.count == 5, let size = Int64(f[1]), let mode = Int(f[2], radix: 8),
      let mtime = Int(f[3]), f[4].hasPrefix("/")
    else { return nil }
    let type = f[0].lowercased()
    let kind: ManifestFile.Kind =
      type.contains("directory")
      ? .directory
      : type.contains("symbolic link") ? .link : type.contains("regular") ? .file : .other
    var path = f[4]
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return (path, ManifestFile(kind: kind, size: size, mode: octal(mode), mtime: mtime))
  }

  /// `0644`-style text of a mode.
  static func octal(_ mode: Int) -> String {
    let digits = String(mode, radix: 8)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
  }

  /// A `sha256sum` or `shasum -a 256` line: 64 hex digits, two spaces (or a space and `*`), the
  /// path. GNU marks names it had to escape with a leading `\`; those are skipped.
  static func hash(_ line: String) -> (String, String)? {
    guard line.count > 66, !line.hasPrefix("\\") else { return nil }
    let hex = line.prefix(64)
    guard hex.allSatisfy(\.isHexDigit) else { return nil }
    let rest = line.dropFirst(64)
    guard rest.hasPrefix("  ") || rest.hasPrefix(" *") else { return nil }
    var path = String(rest.dropFirst(2))
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return (path, hex.lowercased())
  }

  /// The top-level keys of an XML (or any) property list, each value rendered as text.
  static func defaults(_ text: String) -> [String: String]? {
    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: Data(text.utf8), options: [], format: nil),
      let dictionary = plist as? [String: Any]
    else { return nil }
    return dictionary.mapValues(render)
  }

  /// A property list value as text: see `GuestManifest.defaults`.
  static func render(_ value: Any) -> String {
    switch value {
    case let string as String: return string
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "1" : "0" }
      return number.stringValue
    case let date as Date: return ISO8601DateFormatter().string(from: date)
    case let data as Data:
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return "<\(data.count) bytes sha256:\(digest.prefix(16))>"
    case is [Any], is [String: Any]:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return (try? encoder.encode(jsonValue(value))).map { String(decoding: $0, as: UTF8.self) }
        ?? "\(value)"
    default: return "\(value)"
    }
  }

  static func jsonValue(_ value: Any) -> JSONValue {
    switch value {
    case let array as [Any]: return .array(array.map(jsonValue))
    case let dictionary as [String: Any]: return .object(dictionary.mapValues(jsonValue))
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
      return .bool(number.boolValue)
    case let number as NSNumber: return .number(number.doubleValue)
    default: return .string(render(value))
    }
  }
}
