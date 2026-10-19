import Foundation

/// The kernel a Linux guest's own disk boots by default, so a `vz-linux` disk guest can boot it
/// with `VZLinuxBootLoader` and `console=hvc0` from its first boot (R-601, R-602, R-604).
///
/// Virtualization.framework's only serial device is the virtio console (`hvc0`), which an image's
/// GRUB command line does not name: booted through EFI and GRUB, the kernel's messages and panics
/// reach the console only once cloud-init has added `console=hvc0` to GRUB, from the second boot.
/// Before every start vmlab therefore reads the guest's disk (read-only, `Ext4Volume`): the default
/// entry of `grub.cfg` (its kernel, initrd and command line), or without one the `/vmlinuz` and
/// `/initrd.img` links, else the newest `vmlinuz-*` and its initrd, with the command line of
/// `/etc/default/grub` and the root of `/etc/fstab`. It stages the kernel (decompressed: VZ takes
/// only an uncompressed arm64 `Image`) and the initrd in `<vm>/boot-cache/`, copied again only
/// when a source file changed, and boots them with `console=hvc0` last (the last `console=` is
/// `/dev/console`). A disk it cannot read (no ext4 root, LVM, encryption, a compressed EFI
/// kernel) is the caller's cue to boot through EFI as before.
public enum DiskBoot {
  /// `<vm>/boot-cache`, the staged kernel and initrd and the record of where they came from.
  public static let cacheDirectory = "boot-cache"
  static let kernelFile = "vmlinuz"
  static let initrdFile = "initrd.img"
  static let manifestFile = "boot.json"
  /// The most initrds one entry may load (they are concatenated; microcode and the initramfs
  /// make two).
  static let maxInitrds = 8
  /// The virtio console's device name, appended last to the command line.
  public static let console = "console=hvc0"

  /// What the disk boots by default: paths on the guest's file systems and the image's own
  /// command line.
  public struct Entry: Sendable, Hashable {
    public var kernel: String
    public var initrds: [String]
    /// The image's command line, as its boot loader would pass it (without `console=hvc0` added).
    public var arguments: [String]
    /// Where the entry was read: a `grub.cfg` path, or `/boot` when there is none.
    public var source: String

    public init(kernel: String, initrds: [String], arguments: [String], source: String) {
      self.kernel = kernel
      self.initrds = initrds
      self.arguments = arguments
      self.source = source
    }
  }

  /// A boot staged in the cache: host files and the command line to boot them with.
  public struct Staged: Sendable, Hashable {
    /// Host path of the uncompressed kernel `Image`.
    public var kernel: String
    /// Host path of the initrd (several are concatenated into one), if any.
    public var initrd: String?
    /// The image's command line with `console=hvc0` last.
    public var commandLine: String
    public var entry: Entry
    /// Whether this call copied the files anew (false: the cache matched the disk).
    public var refreshed: Bool

    public init(
      kernel: String, initrd: String?, commandLine: String, entry: Entry, refreshed: Bool
    ) {
      self.kernel = kernel
      self.initrd = initrd
      self.commandLine = commandLine
      self.entry = entry
      self.refreshed = refreshed
    }
  }

  /// One source file's identity on the disk: when any part changes, the cache is stale.
  struct FileKey: Codable, Sendable, Hashable {
    var offset: UInt64
    var inode: UInt32
    var size: UInt64
    var modified: UInt32
    var changed: UInt32
  }

  /// `boot.json`: the sources the cached files were copied from.
  struct Manifest: Codable, Sendable, Hashable {
    var kernel: FileKey
    var initrds: [FileKey]
  }

  struct Located {
    var entry: Entry
    var kernel: (volume: Ext4Volume, inode: Ext4Volume.Inode)
    var initrds: [(volume: Ext4Volume, inode: Ext4Volume.Inode)]
  }

  // MARK: Staging

  /// Reads the default boot entry of the raw disk `disk` and stages it in `cache` (created when
  /// absent), reusing the files there when their sources are unchanged. Throws (`engine_error`)
  /// when the disk's boot cannot be read or its kernel is not an arm64 `Image`.
  public static func stage(disk: URL, cache: URL) throws(VMLabError) -> Staged {
    let found = try locate(disk: disk)
    let key = Manifest(
      kernel: fileKey(found.kernel), initrds: found.initrds.map { fileKey($0) })
    let kernel = cache.appending(path: kernelFile)
    let initrd = cache.appending(path: initrdFile)
    let manifest = cache.appending(path: manifestFile)
    let files = FileManager.default
    let current =
      (try? Data(contentsOf: manifest)).flatMap {
        try? JSONDecoder().decode(Manifest.self, from: $0)
      }
    let staged =
      current == key && files.fileExists(atPath: kernel.path)
      && (key.initrds.isEmpty || files.fileExists(atPath: initrd.path))
    if !staged {
      do {
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
      } catch {
        throw unavailable("cannot create \(cache.path): \(error.localizedDescription)")
      }
      // The manifest goes first and comes back last: a copy cut short is redone next time.
      try? files.removeItem(at: manifest)
      let newKernel = cache.appending(path: ".\(kernelFile).new")
      let newInitrd = cache.appending(path: ".\(initrdFile).new")
      defer {
        try? files.removeItem(at: newKernel)
        try? files.removeItem(at: newInitrd)
      }
      try found.kernel.volume.copy(found.kernel.inode, to: newKernel)
      try Gzip.decompressInPlace(newKernel)
      try checkImage(newKernel, guestPath: found.entry.kernel)
      if !found.initrds.isEmpty { try concatenate(found.initrds, to: newInitrd) }
      do {
        try replace(kernel, with: newKernel)
        if found.initrds.isEmpty {
          try? files.removeItem(at: initrd)
        } else {
          try replace(initrd, with: newInitrd)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(key).write(to: manifest, options: .atomic)
      } catch {
        throw unavailable(
          "cannot write the boot cache \(cache.path): \(error.localizedDescription)")
      }
    }
    return Staged(
      kernel: kernel.path, initrd: found.initrds.isEmpty ? nil : initrd.path,
      commandLine: commandLine(found.entry.arguments), entry: found.entry, refreshed: !staged)
  }

  /// `arguments` with every `console=hvc0` moved to the end, once: the last `console=` becomes
  /// `/dev/console`, and the image's other consoles still get the kernel's messages.
  public static func commandLine(_ arguments: [String]) -> String {
    let others = arguments.filter { $0 != console && !$0.hasPrefix(console + ",") }
    return (others + [console]).joined(separator: " ")
  }

  static func fileKey(_ file: (volume: Ext4Volume, inode: Ext4Volume.Inode)) -> FileKey {
    FileKey(
      offset: file.volume.base, inode: file.inode.number, size: file.inode.size,
      modified: file.inode.modified, changed: file.inode.changed)
  }

  /// An arm64 `Image` has `ARM\x64` at byte 56; VZ boots nothing else (an EFI zboot kernel, a
  /// `vmlinux` ELF or a kernel for another architecture boots only through EFI).
  static func checkImage(_ url: URL, guestPath: String) throws(VMLabError) {
    let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle in
      defer { try? handle.close() }
      return try? handle.read(upToCount: 64)
    }
    guard let head, head.count >= 60, head.subdata(in: 56..<60) == Data("ARM\u{64}".utf8) else {
      throw unavailable(
        "\(guestPath) is not an arm64 Image (uncompressed or gzip), which is all "
          + "Virtualization.framework boots directly")
    }
  }

  static func concatenate(
    _ files: [(volume: Ext4Volume, inode: Ext4Volume.Inode)], to destination: URL
  ) throws(VMLabError) {
    guard let first = files.first else { return }
    try first.volume.copy(first.inode, to: destination)
    guard files.count > 1 else { return }
    let part = destination.appendingPathExtension("part")
    defer { try? FileManager.default.removeItem(at: part) }
    do {
      let out = try FileHandle(forWritingTo: destination)
      defer { try? out.close() }
      try out.seekToEnd()
      for file in files.dropFirst() {
        try file.volume.copy(file.inode, to: part)
        let input = try FileHandle(forReadingFrom: part)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
          try out.write(contentsOf: chunk)
        }
      }
    } catch let error as VMLabError {
      throw error
    } catch {
      throw unavailable("cannot join the initrds: \(error.localizedDescription)")
    }
  }

  static func replace(_ target: URL, with source: URL) throws {
    if FileManager.default.fileExists(atPath: target.path) {
      _ = try FileManager.default.replaceItemAt(target, withItemAt: source)
    } else {
      try FileManager.default.moveItem(at: source, to: target)
    }
  }

  static func unavailable(_ reason: String) -> VMLabError {
    VMLabError(
      code: .engineError, message: "Cannot boot the guest's kernel from its disk: \(reason).",
      hint: "The guest boots through EFI and GRUB instead.",
      data: ["engine": .string("ext4"), "raw": .string(reason)])
  }

  // MARK: Finding the default entry

  /// The disk's default boot entry and its files: `grub.cfg` first, else the `/boot` links or
  /// newest kernel with `/etc/default/grub`'s command line.
  static func locate(disk: URL) throws(VMLabError) -> Located {
    var offsets = (try? Ext4Volume.partitions(of: disk).map(\.offset)) ?? []
    if offsets.isEmpty { offsets = [0] }
    let volumes = offsets.compactMap { try? Ext4Volume(image: disk, offset: $0) }
    guard !volumes.isEmpty else {
      throw unavailable(
        "no ext4 file system on \(disk.lastPathComponent) (the root may be on LVM, encrypted, "
          + "btrfs or xfs)")
    }
    func file(_ path: String, on volume: Ext4Volume) -> Ext4Volume.Inode? {
      guard let inode = try? volume.lookup(path), inode.kind == .file else { return nil }
      return inode
    }
    for volume in volumes {
      for path in [
        "/boot/grub/grub.cfg", "/grub/grub.cfg", "/boot/grub2/grub.cfg", "/grub2/grub.cfg",
      ] {
        guard let config = file(path, on: volume), let data = try? volume.contents(of: config),
          let entry = GrubConfig.defaultEntry(String(decoding: data, as: UTF8.self))
        else { continue }
        // An initrd line of a crafted disk must not have the host copy the disk many times over.
        guard entry.initrds.count <= maxInitrds else {
          throw unavailable("\(path)'s default entry loads \(entry.initrds.count) initrds")
        }
        // GRUB reads the paths on the file system its `search` found: the one holding grub.cfg,
        // as a rule, else another.
        for candidate in [volume] + volumes.filter({ $0 !== volume }) {
          guard let kernel = file(entry.kernel, on: candidate) else { continue }
          let initrds = entry.initrds.compactMap { file($0, on: candidate) }
          guard initrds.count == entry.initrds.count else { continue }
          return Located(
            entry: Entry(
              kernel: entry.kernel, initrds: entry.initrds, arguments: entry.arguments,
              source: path),
            kernel: (candidate, kernel), initrds: initrds.map { (candidate, $0) })
        }
        throw unavailable("\(path)'s default entry boots \(entry.kernel), which is not on the disk")
      }
    }
    return try locateWithoutGrub(volumes)
  }

  /// No `grub.cfg`: `/vmlinuz` and `/initrd.img` (or in `/boot`), else the newest `vmlinuz-*`
  /// and its initrd; the command line of `/etc/default/grub` with the root `/etc/fstab` mounts.
  static func locateWithoutGrub(_ volumes: [Ext4Volume]) throws(VMLabError) -> Located {
    func resolved(_ link: String, on volume: Ext4Volume) -> String? {
      guard let inode = try? volume.lookup(link, follow: false), inode.kind == .symlink,
        let target = try? volume.readLink(inode), (try? volume.lookup(link))?.kind == .file
      else { return nil }
      if target.hasPrefix("/") { return target }
      let directory = (link as NSString).deletingLastPathComponent
      return (directory == "/" ? "" : directory) + "/" + target
    }
    var found: (volume: Ext4Volume, kernel: String, initrd: String?)?
    search: for volume in volumes {
      for directory in ["/boot", ""] {
        if let kernel = resolved(directory + "/vmlinuz", on: volume) {
          found = (volume, kernel, resolved(directory + "/initrd.img", on: volume))
          break search
        }
      }
    }
    if found == nil {
      newest: for volume in volumes {
        for directory in ["/boot", "/"] {
          guard let inode = try? volume.lookup(directory), inode.kind == .directory,
            let names = (try? volume.entries(of: inode))?.map(\.name)
          else { continue }
          let versions = names.filter { $0.hasPrefix("vmlinuz-") }.map { $0.dropFirst(8) }
          guard
            let version = versions.max(by: {
              String($0).compare(String($1), options: .numeric) == .orderedAscending
            })
          else { continue }
          let prefix = directory == "/" ? "/" : directory + "/"
          let initrd = ["initrd.img-\(version)", "initramfs-\(version).img"].first {
            names.contains($0)
          }
          found = (volume, prefix + "vmlinuz-\(version)", initrd.map { prefix + $0 })
          break newest
        }
      }
    }
    guard let found, let kernel = try? found.volume.lookup(found.kernel), kernel.kind == .file
    else { throw unavailable("no kernel (vmlinuz) in /boot and no grub.cfg") }
    let initrd = found.initrd.flatMap { try? found.volume.lookup($0) }.flatMap {
      $0.kind == .file ? $0 : nil
    }
    let root = volumes.first { (try? $0.lookup("/etc/fstab"))?.kind == .file } ?? found.volume
    let text = { (path: String) -> String? in
      (try? root.lookup(path)).flatMap { try? root.contents(of: $0) }.map {
        String(decoding: $0, as: UTF8.self)
      }
    }
    var defaults = [text("/etc/default/grub")].compactMap { $0 }
    if let directory = try? root.lookup("/etc/default/grub.d"), directory.kind == .directory,
      let names = try? root.entries(of: directory).map(\.name)
    {
      defaults += names.filter { $0.hasSuffix(".cfg") }.sorted().compactMap {
        text("/etc/default/grub.d/\($0)")
      }
    }
    let spec = text("/etc/fstab").flatMap(GrubConfig.rootSpec) ?? "UUID=\(root.uuid)"
    let arguments = ["root=\(spec)", "ro"] + GrubConfig.defaultArguments(defaults)
    return Located(
      entry: Entry(
        kernel: found.kernel, initrds: initrd == nil ? [] : [found.initrd].compactMap { $0 },
        arguments: arguments, source: "/boot"),
      kernel: (found.volume, kernel), initrds: initrd.map { [(found.volume, $0)] } ?? [])
  }
}

/// Just enough of GRUB's configuration language to find what its default entry boots.
enum GrubConfig {
  struct MenuEntry: Equatable {
    var title: String
    var id: String?
    var linux: [String]?
    var initrds: [String]
    /// A submenu's entries; nil for a menu entry.
    var children: [MenuEntry]?
  }

  /// The default entry's kernel path, initrd paths and command line (tokens holding a GRUB
  /// variable dropped). `set default=` is honoured when literal (an index, a title or an id, or a
  /// `>`-separated path into submenus), else the first entry boots. Nil without a `linux` line.
  static func defaultEntry(
    _ text: String
  ) -> (kernel: String, initrds: [String], arguments: [String])? {
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    var index = 0
    let menu = parse(lines, &index, nested: false).entries
    var chosen: String?
    for line in lines where line.hasPrefix("set default=") {
      let value = unquote(String(line.dropFirst("set default=".count)))
      if !value.contains("$"), !value.isEmpty { chosen = value }
    }
    var entries = menu
    var entry: MenuEntry?
    for part in (chosen ?? "0").split(separator: ">").map(String.init) {
      let pick =
        Int(part).flatMap { entries.indices.contains($0) ? entries[$0] : nil }
        ?? entries.first { $0.title == part || $0.id == part }
      guard let pick else {
        entry = nil
        break
      }
      entry = pick
      entries = pick.children ?? []
    }
    var target = entry ?? menu.first
    while let submenu = target?.children { target = submenu.first }
    guard let linux = target?.linux, linux.count >= 2 else { return nil }
    return (linux[1], target?.initrds ?? [], Array(linux.dropFirst(2)))
  }

  struct Block {
    var entries: [MenuEntry] = []
    var linux: [String]?
    var initrds: [String] = []
  }

  static func parse(_ lines: [String], _ index: inout Int, nested: Bool) -> Block {
    var block = Block()
    while index < lines.count {
      let line = lines[index]
      index += 1
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("}") {
        if nested { return block }
        continue
      }
      let words = tokens(line)
      guard let first = words.first else { continue }
      if line.hasSuffix("{") {
        let child = parse(lines, &index, nested: true)
        guard first == "menuentry" || first == "submenu" else { continue }
        let raw = rawTokens(line)
        let id = raw.firstIndex { $0 == "$menuentry_id_option" || $0 == "--id" }.flatMap {
          raw.indices.contains($0 + 1) ? unquote(raw[$0 + 1]) : nil
        }
        block.entries.append(
          MenuEntry(
            title: words.count > 1 ? words[1] : "", id: id, linux: child.linux,
            initrds: child.initrds, children: first == "submenu" ? child.entries : nil))
        continue
      }
      switch first {
      case "linux", "linuxefi", "linux16":
        if block.linux == nil { block.linux = words.filter { !$0.contains("$") } }
      case "initrd", "initrdefi", "initrd16":
        if block.initrds.isEmpty { block.initrds = Array(words.dropFirst()) }
      default: break
      }
    }
    return block
  }

  /// A line's words, quotes removed.
  static func tokens(_ line: String) -> [String] { rawTokens(line).map(unquote) }

  /// A line's words split on blanks outside quotes, quotes kept.
  static func rawTokens(_ line: String) -> [String] {
    var words: [String] = []
    var word = ""
    var quote: Character?
    var escaped = false
    var any = false
    for character in line {
      if escaped {
        word.append(character)
        escaped = false
      } else if character == "\\" && quote != "'" {
        word.append(character)
        escaped = true
      } else if let open = quote {
        word.append(character)
        if character == open { quote = nil }
      } else if character == "'" || character == "\"" {
        word.append(character)
        quote = character
        any = true
      } else if character == " " || character == "\t" {
        if !word.isEmpty || any { words.append(word) }
        word = ""
        any = false
      } else {
        word.append(character)
      }
    }
    if !word.isEmpty || any { words.append(word) }
    return words
  }

  /// A word with its quotes and backslashes removed.
  static func unquote(_ word: String) -> String {
    var out = ""
    var quote: Character?
    var escaped = false
    for character in word {
      if escaped {
        out.append(character)
        escaped = false
      } else if character == "\\" && quote != "'" {
        escaped = true
      } else if let open = quote {
        if character == open { quote = nil } else { out.append(character) }
      } else if character == "'" || character == "\"" {
        quote = character
      } else {
        out.append(character)
      }
    }
    return out
  }

  /// `GRUB_CMDLINE_LINUX` then `GRUB_CMDLINE_LINUX_DEFAULT`, as `update-grub` puts them on the
  /// default entry, from `/etc/default/grub` and its `grub.d` files in order (a later assignment
  /// wins; `$GRUB_CMDLINE_LINUX…` in a value is the earlier value).
  static func defaultArguments(_ files: [String]) -> [String] {
    var values: [String: String] = [:]
    let names = ["GRUB_CMDLINE_LINUX", "GRUB_CMDLINE_LINUX_DEFAULT"]
    for text in files {
      for raw in text.split(whereSeparator: \.isNewline) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
        for name in names where line.hasPrefix(name + "=") {
          var value = unquote(String(line.dropFirst(name.count + 1)))
          for previous in names.reversed() {
            for spelling in ["${\(previous)}", "$\(previous)"] {
              value = value.replacingOccurrences(of: spelling, with: values[previous] ?? "")
            }
          }
          values[name] = value
        }
      }
    }
    return names.flatMap { (values[$0] ?? "").split(separator: " ").map(String.init) }
      .filter { !$0.contains("$") }
  }

  /// The device `/etc/fstab` mounts at `/` (`UUID=…`, `PARTUUID=…`, `LABEL=…` or a path).
  static func rootSpec(_ fstab: String) -> String? {
    for raw in fstab.split(whereSeparator: \.isNewline) {
      let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      if fields.count >= 2, !fields[0].hasPrefix("#"), fields[1] == "/" { return fields[0] }
    }
    return nil
  }
}
