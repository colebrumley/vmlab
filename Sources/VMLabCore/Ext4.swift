import Foundation

/// A read-only reader for the partitions of a raw GPT disk image and the ext4 file systems on
/// them, enough to copy `/boot` out of a Linux cloud image (R-305, Appendix H). macOS cannot mount
/// ext4 (`hdiutil` attaches the raw disk but no driver reads the partition), so vmlab reads it
/// itself. It understands extent-mapped and block-mapped files, linear and hashed directories
/// (read linearly) and fast and slow symlinks; it never writes.
public final class Ext4Volume {
  /// One GPT partition: 1-based index and byte range.
  public struct Partition: Sendable, Hashable {
    public var index: Int
    public var offset: UInt64
    public var length: UInt64
  }

  /// A directory entry.
  public struct Entry: Sendable, Hashable {
    public var name: String
    public var inode: UInt32
  }

  /// What an inode is, from its mode bits.
  public enum Kind: Sendable, Hashable { case file, directory, symlink, other }

  public struct Inode: Sendable, Hashable {
    public var number: UInt32
    public var kind: Kind
    public var size: UInt64
    var flags: UInt32
    var block: Data
  }

  let handle: FileHandle
  let base: UInt64
  let blockSize: UInt64
  let inodesPerGroup: UInt32
  let inodeSize: UInt64
  let descriptorSize: UInt64
  let descriptorTable: UInt64

  static let rootInode: UInt32 = 2

  /// Opens the ext4 file system that starts `offset` bytes into `image`.
  public init(image: URL, offset: UInt64 = 0) throws(VMLabError) {
    do {
      handle = try FileHandle(forReadingFrom: image)
    } catch {
      throw Self.error("cannot open \(image.path): \(error.localizedDescription)")
    }
    base = offset
    let superblock = try Self.read(handle, at: offset + 1024, count: 1024)
    guard superblock.u16(56) == 0xEF53 else {
      try? handle.close()
      throw Self.error("no ext4 file system at offset \(offset)")
    }
    blockSize = 1024 << UInt64(superblock.u32(24))
    inodesPerGroup = superblock.u32(40)
    let revision = superblock.u32(76)
    inodeSize = revision == 0 ? 128 : UInt64(superblock.u16(88))
    let incompat = superblock.u32(96)
    let is64 = incompat & 0x80 != 0
    descriptorSize = is64 ? max(64, UInt64(superblock.u16(254))) : 32
    let firstDataBlock = UInt64(superblock.u32(20))
    descriptorTable = (firstDataBlock + 1) * blockSize
  }

  deinit { try? handle.close() }

  /// The partitions of a GPT disk image (512-byte sectors), in table order.
  public static func partitions(of image: URL) throws(VMLabError) -> [Partition] {
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: image) } catch {
      throw Self.error("cannot open \(image.path): \(error.localizedDescription)")
    }
    defer { try? handle.close() }
    let header = try read(handle, at: 512, count: 92)
    guard header.prefix(8) == Data("EFI PART".utf8) else {
      throw Self.error("\(image.lastPathComponent) has no GPT partition table")
    }
    let entries = header.u64(72)
    let count = min(Int(header.u32(80)), 256)
    let size = Int(header.u32(84))
    guard size >= 128 else { throw Self.error("bad GPT entry size \(size)") }
    let table = try read(handle, at: entries * 512, count: count * size)
    var result: [Partition] = []
    for index in 0..<count {
      let entry = table.subdata(in: index * size..<(index + 1) * size)
      guard entry.prefix(16).contains(where: { $0 != 0 }) else { continue }
      let first = entry.u64(32)
      let last = entry.u64(40)
      guard last >= first else { continue }
      result.append(
        Partition(index: index + 1, offset: first * 512, length: (last - first + 1) * 512))
    }
    return result
  }

  // MARK: Lookup

  /// The inode at `path` (absolute, inside this file system), following symlinks on the way and,
  /// when `follow` is set, at the end.
  public func lookup(_ path: String, follow: Bool = true) throws(VMLabError) -> Inode {
    try lookup(path, follow: follow, depth: 0)
  }

  private func lookup(_ path: String, follow: Bool, depth: Int) throws(VMLabError) -> Inode {
    guard depth < 16 else { throw Self.error("too many symlinks resolving \(path)") }
    var current = try inode(Self.rootInode)
    var walked: [String] = []
    let parts = path.split(separator: "/").map(String.init)
    for (position, part) in parts.enumerated() {
      if part == "." { continue }
      if part == ".." {
        walked = walked.dropLast()
        current = try lookup("/" + walked.joined(separator: "/"), follow: true, depth: depth + 1)
        continue
      }
      guard current.kind == .directory else { throw Self.error("\(part) is not in a directory") }
      guard let entry = try entries(of: current).first(where: { $0.name == part }) else {
        throw Self.error("\(path) does not exist")
      }
      var next = try inode(entry.inode)
      let last = position == parts.count - 1
      if next.kind == .symlink, follow || !last {
        let target = try readLink(next)
        let resolved =
          target.hasPrefix("/")
          ? target : "/" + (walked + [target]).joined(separator: "/")
        next = try lookup(resolved, follow: true, depth: depth + 1)
        walked = resolved.split(separator: "/").map(String.init)
      } else {
        walked.append(part)
      }
      current = next
    }
    return current
  }

  /// The entries of a directory, without `.` and `..`.
  public func entries(of directory: Inode) throws(VMLabError) -> [Entry] {
    guard directory.kind == .directory else { throw Self.error("inode is not a directory") }
    let data = try contents(of: directory)
    var result: [Entry] = []
    var offset = 0
    while offset + 8 <= data.count {
      let number = data.u32(offset)
      let length = Int(data.u16(offset + 4))
      let nameLength = Int(data[data.startIndex + offset + 6])
      guard length >= 8, offset + length <= data.count else { break }
      if number != 0, nameLength > 0, offset + 8 + nameLength <= data.count {
        let start = data.startIndex + offset + 8
        let name = String(decoding: data[start..<start + nameLength], as: UTF8.self)
        if name != ".", name != ".." { result.append(Entry(name: name, inode: number)) }
      }
      offset += length
    }
    return result
  }

  /// The target of a symlink.
  public func readLink(_ inode: Inode) throws(VMLabError) -> String {
    guard inode.kind == .symlink else { throw Self.error("inode is not a symlink") }
    // A fast symlink keeps its target in i_block (no extents, under 60 bytes).
    if inode.size < 60, inode.flags & 0x80000 == 0 {
      return String(decoding: inode.block.prefix(Int(inode.size)), as: UTF8.self)
    }
    return String(decoding: try contents(of: inode), as: UTF8.self)
  }

  /// A file's whole contents (directories and symlinks too).
  public func contents(of inode: Inode) throws(VMLabError) -> Data {
    var data = Data(count: Int(inode.size))
    try forEachRun(of: inode) { (offset: UInt64, bytes: Data) throws(VMLabError) in
      let end = min(Int(offset) + bytes.count, data.count)
      guard Int(offset) < end else { return }
      data.replaceSubrange(Int(offset)..<end, with: bytes.prefix(end - Int(offset)))
    }
    return data
  }

  /// Copies a regular file to `destination` (replacing it), streaming extent by extent.
  public func copy(_ inode: Inode, to destination: URL) throws(VMLabError) {
    guard inode.kind == .file else { throw Self.error("inode \(inode.number) is not a file") }
    let files = FileManager.default
    try? files.removeItem(at: destination)
    guard files.createFile(atPath: destination.path, contents: nil),
      let out = try? FileHandle(forWritingTo: destination)
    else { throw Self.error("cannot write \(destination.path)") }
    defer { try? out.close() }
    let size = inode.size
    do {
      try forEachRun(of: inode) { (offset: UInt64, bytes: Data) throws(VMLabError) in
        guard offset < size else { return }
        do {
          try out.seek(toOffset: offset)
          try out.write(contentsOf: bytes.prefix(Int(size - offset)))
        } catch {
          throw Self.error("cannot write \(destination.path): \(error.localizedDescription)")
        }
      }
      try out.truncate(atOffset: size)
    } catch let error as VMLabError {
      throw error
    } catch {
      throw Self.error("cannot write \(destination.path): \(error.localizedDescription)")
    }
  }

  // MARK: Inodes and blocks

  func inode(_ number: UInt32) throws(VMLabError) -> Inode {
    guard number > 0 else { throw Self.error("inode 0") }
    let group = UInt64((number - 1) / inodesPerGroup)
    let index = UInt64((number - 1) % inodesPerGroup)
    let descriptor = try read(at: descriptorTable + group * descriptorSize, count: 64)
    var table = UInt64(descriptor.u32(8))
    if descriptorSize >= 64 { table |= UInt64(descriptor.u32(0x28)) << 32 }
    let raw = try read(at: table * blockSize + index * inodeSize, count: 160)
    let mode = raw.u16(0)
    let kind: Kind =
      switch mode & 0xF000 {
      case 0x8000: .file
      case 0x4000: .directory
      case 0xA000: .symlink
      default: .other
      }
    let size = UInt64(raw.u32(4)) | UInt64(raw.u32(0x6C)) << 32
    return Inode(
      number: number, kind: kind, size: size, flags: raw.u32(0x20),
      block: raw.subdata(in: 0x28..<0x28 + 60))
  }

  /// Calls `body` with each mapped run of the file (logical byte offset, bytes), in order. Holes
  /// and unwritten extents are skipped (the caller's buffer or file reads them as zeros).
  func forEachRun(
    of inode: Inode, _ body: (UInt64, Data) throws(VMLabError) -> Void
  ) throws(VMLabError) {
    if inode.flags & 0x80000 != 0 {
      try walkExtents(node: inode.block, depth: 0, body)
    } else {
      let blocks = (inode.size + blockSize - 1) / blockSize
      for logical in 0..<blocks {
        guard let physical = try mappedBlock(inode.block, logical), physical != 0 else { continue }
        try body(logical * blockSize, try read(at: physical * blockSize, count: Int(blockSize)))
      }
    }
  }

  private func walkExtents(
    node: Data, depth: Int, _ body: (UInt64, Data) throws(VMLabError) -> Void
  ) throws(VMLabError) {
    guard depth < 8, node.u16(0) == 0xF30A else { throw Self.error("bad extent header") }
    let count = Int(node.u16(2))
    let level = node.u16(6)
    for index in 0..<count {
      let at = 12 + index * 12
      guard at + 12 <= node.count else { break }
      if level == 0 {
        let logical = UInt64(node.u32(at))
        var length = UInt64(node.u16(at + 4))
        let unwritten = length > 32768
        if unwritten { length -= 32768 }
        let start = UInt64(node.u16(at + 6)) << 32 | UInt64(node.u32(at + 8))
        guard !unwritten else { continue }
        // Read in chunks of at most 8 MB so a big kernel never needs one huge buffer.
        var done: UInt64 = 0
        while done < length {
          let chunk = min(length - done, (8 << 20) / blockSize)
          let bytes = try read(at: (start + done) * blockSize, count: Int(chunk * blockSize))
          try body((logical + done) * blockSize, bytes)
          done += chunk
        }
      } else {
        let leaf = UInt64(node.u16(at + 8)) << 32 | UInt64(node.u32(at + 4))
        let child = try read(at: leaf * blockSize, count: Int(blockSize))
        try walkExtents(node: child, depth: depth + 1, body)
      }
    }
  }

  /// The physical block of `logical` in a block-mapped (pre-extent) file, or nil in a hole.
  private func mappedBlock(_ map: Data, _ logical: UInt64) throws(VMLabError) -> UInt64? {
    let perBlock = blockSize / 4
    var index = logical
    if index < 12 { return UInt64(map.u32(Int(index) * 4)) }
    index -= 12
    var levels: [UInt64] = []
    var root = 0
    if index < perBlock {
      levels = [index]
      root = 12
    } else if index - perBlock < perBlock * perBlock {
      index -= perBlock
      levels = [index / perBlock, index % perBlock]
      root = 13
    } else {
      index -= perBlock + perBlock * perBlock
      levels = [index / (perBlock * perBlock), index / perBlock % perBlock, index % perBlock]
      root = 14
    }
    var block = UInt64(map.u32(root * 4))
    for slot in levels {
      guard block != 0 else { return nil }
      block = UInt64(try read(at: block * blockSize + slot * 4, count: 4).u32(0))
    }
    return block
  }

  private func read(at offset: UInt64, count: Int) throws(VMLabError) -> Data {
    try Self.read(handle, at: base + offset, count: count)
  }

  static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws(VMLabError) -> Data {
    do {
      try handle.seek(toOffset: offset)
      let data = try handle.read(upToCount: count) ?? Data()
      guard data.count == count else { throw Self.error("short read at \(offset)") }
      return data
    } catch let error as VMLabError {
      throw error
    } catch {
      throw Self.error("read failed at \(offset): \(error.localizedDescription)")
    }
  }

  static func error(_ reason: String) -> VMLabError {
    VMLabError(
      code: .engineError, message: "Could not read the image's file system: \(reason).",
      hint: "Check that the image is a Linux disk with an ext4 root; pull it again if damaged.",
      data: ["engine": .string("ext4"), "raw": .string(reason)])
  }
}

extension Data {
  fileprivate func u16(_ offset: Int) -> UInt16 {
    let i = startIndex + offset
    return UInt16(self[i]) | UInt16(self[i + 1]) << 8
  }

  fileprivate func u32(_ offset: Int) -> UInt32 {
    let i = startIndex + offset
    return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16
      | UInt32(self[i + 3]) << 24
  }

  fileprivate func u64(_ offset: Int) -> UInt64 {
    UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
  }
}
