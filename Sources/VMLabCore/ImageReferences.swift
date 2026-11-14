import Foundation

/// What a disk image's own header points at, read without opening anything it names. A qcow2
/// names a backing file and an external data file, and QEMU and `qemu-img` open both, as files
/// or as `nbd://`, `http://` and `json:` references: a model-named image (`images register`,
/// a `file=` in `extra.qemuArgs`) is scanned here before either tool sees it, so a crafted header
/// cannot make the host read `~/.ssh/id_ed25519` as a disk or connect somewhere for the guest.
public enum ImageReferences {
  /// The names a qcow2 header carries, as written (relative to the image's directory).
  public struct QCOW2: Sendable, Hashable {
    public var backing: String?
    public var dataFile: String?

    public init(backing: String? = nil, dataFile: String? = nil) {
      self.backing = backing
      self.dataFile = dataFile
    }

    public var all: [String] { [backing, dataFile].compactMap { $0 } }
  }

  public enum Kind: Sendable, Hashable {
    /// No header vmlab knows: a raw disk, which names nothing.
    case plain
    case qcow2(QCOW2)
    /// A format whose references vmlab does not read (VMDK extents, a QED or VHDX parent), or
    /// a qcow2 whose header does not parse; the name says which.
    case opaque(String)
  }

  /// How much of the file is read: a qcow2's header, extensions and backing name lie in its
  /// first cluster, which is at most 2 MiB.
  static let window = 2 << 20

  public static func scan(_ url: URL) -> Kind {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .plain }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: window + 1)) ?? Data()
    return scan(data, truncated: data.count > window)
  }

  /// `data` is the start of the file; `truncated` says the file goes on past it.
  static func scan(_ data: Data, truncated: Bool = false) -> Kind {
    let bytes = [UInt8](data.prefix(window))
    func starts(_ magic: [UInt8]) -> Bool {
      bytes.count >= magic.count && bytes.starts(with: magic)
    }
    if starts([0x51, 0x46, 0x49, 0xFB]) {
      return qcow2(bytes, truncated: truncated).map(Kind.qcow2)
        ?? .opaque("a qcow2 image whose header vmlab cannot read")
    }
    for (magic, name) in [
      ("KDMV", "VMDK"), ("COWD", "VMDK"), ("QED\0", "QED"), ("vhdxfile", "VHDX"),
      ("WithoutFreeSpace", "Parallels"), ("WithouFreSpacExt", "Parallels"),
    ] where starts(Array(magic.utf8)) {
      return .opaque(name)
    }
    let text = String(decoding: bytes.prefix(512), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.hasPrefix("# disk descriptorfile") { return .opaque("VMDK") }
    return .plain
  }

  /// The qcow2 header's references, or nil when the header does not parse.
  static func qcow2(_ bytes: [UInt8], truncated _: Bool) -> QCOW2? {
    func u32(_ at: Int) -> Int? {
      guard at >= 0, at + 4 <= bytes.count else { return nil }
      return bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
    }
    func u64(_ at: Int) -> UInt64? {
      guard at >= 0, at + 8 <= bytes.count else { return nil }
      return bytes[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
    func string(_ at: Int, _ length: Int) -> String? {
      guard at >= 0, length >= 0, at + length <= bytes.count else { return nil }
      return String(decoding: bytes[at..<at + length], as: UTF8.self)
    }
    guard bytes.count >= 72, let version = u32(4), version == 2 || version == 3,
      let backingOffset = u64(8), let backingSize = u32(16)
    else { return nil }
    var found = QCOW2()
    if backingOffset != 0, backingSize != 0 {
      guard backingOffset < UInt64(window), let name = string(Int(backingOffset), backingSize)
      else { return nil }
      found.backing = name
    }
    var position = 72
    var externalData = false
    if version == 3 {
      guard let incompatible = u64(72), let length = u32(100), length >= 104 else { return nil }
      externalData = incompatible & 0b100 != 0
      position = length
    }
    // Extensions run to the backing name, or to the end of the first cluster.
    let end = backingOffset != 0 ? min(Int(backingOffset), bytes.count) : bytes.count
    while position + 8 <= end {
      guard let type = u32(position), let length = u32(position + 4) else { return nil }
      if type == 0 { break }
      if type == 0x4441_5441 {
        guard let name = string(position + 8, length) else { return nil }
        found.dataFile = name
      }
      position += 8 + (length + 7) & ~7
    }
    // The header says there is a data file and none was found: it lies past what was read.
    if externalData, found.dataFile == nil { return nil }
    return found
  }

  /// Whether QEMU reads `name` as a file path: no `json:` and no protocol (`nbd://`, `http:`,
  /// `ssh://`), which is how QEMU itself tells (`path_has_protocol`: a colon before any slash).
  public static func isLocalPath(_ name: String) -> Bool {
    guard !name.isEmpty, let first = name.first(where: { $0 == ":" || $0 == "/" }) else {
      return !name.isEmpty
    }
    return first == "/"
  }

  /// The absolute path of `name` as an image at `image` names it.
  public static func resolve(_ name: String, from image: URL) -> String {
    name.hasPrefix("/") ? name : image.deletingLastPathComponent().appending(path: name).path
  }
}
