import Foundation
import Testing
import VMLabCore

/// Builds a tiny GPT disk with one ext4 partition (1 KB blocks, one group, 32-bit descriptors),
/// laid out by hand so the reader is tested without `mkfs.ext4` on the host. It holds a Debian-like
/// `/boot` with two kernel versions, an extent file with a hole, a block-mapped file, a two-level
/// extent tree, and fast and slow symlinks.
struct Ext4Fixture {
  static let block = 1024
  static let partitionLBA = 64
  static let blocks = 64

  var fs = Data(count: blocks * block)
  var next = 12

  static let kernel =
    Data(repeating: 0x41, count: 1024) + Data(count: 1024)
    + Data(repeating: 0x43, count: 1024)
  static let initrd = Data((0..<1500).map { UInt8($0 % 251) })
  static let config = Data("CONFIG_VIRTIO_BLK=y\n".utf8)
  static let systemMap = Data("ffffffffffffffff B The real System.map is elsewhere\n".utf8)
  static let longTarget = "/boot/" + String(repeating: "x", count: 70)

  mutating func put16(_ value: Int, _ at: Int) {
    fs[at] = UInt8(value & 0xff)
    fs[at + 1] = UInt8(value >> 8 & 0xff)
  }

  mutating func put32(_ value: Int, _ at: Int) {
    for i in 0..<4 { fs[at + i] = UInt8(value >> (8 * i) & 0xff) }
  }

  /// Copies `data` into fresh blocks; returns the first.
  mutating func allocate(_ data: Data) -> Int {
    let start = next
    let count = max(1, (data.count + Self.block - 1) / Self.block)
    fs.replaceSubrange(start * Self.block..<start * Self.block + data.count, with: data)
    next += count
    return start
  }

  /// An extent header plus `(logical, length, start)` leaf entries, padded to 60 bytes.
  static func extents(_ runs: [(Int, Int, Int)], depth: Int = 0, size: Int = 60) -> Data {
    var d = Data(count: size)
    func p16(_ v: Int, _ at: Int) {
      d[at] = UInt8(v & 0xff)
      d[at + 1] = UInt8(v >> 8)
    }
    func p32(_ v: Int, _ at: Int) { for i in 0..<4 { d[at + i] = UInt8(v >> (8 * i) & 0xff) } }
    p16(0xF30A, 0)
    p16(runs.count, 2)
    p16((size - 12) / 12, 4)
    p16(depth, 6)
    for (i, run) in runs.enumerated() {
      let at = 12 + i * 12
      p32(run.0, at)
      if depth == 0 {
        p16(run.1, at + 4)
        p32(run.2, at + 8)
      } else {
        p32(run.2, at + 4)
      }
    }
    return d
  }

  mutating func inode(_ n: Int, mode: Int, size: Int, flags: Int, block: Data) {
    let at = 4 * Self.block + (n - 1) * 256
    put16(mode, at)
    put32(size, at + 4)
    put32(flags, at + 0x20)
    fs.replaceSubrange(at + 0x28..<at + 0x28 + block.count, with: block)
  }

  mutating func file(_ n: Int, _ data: Data) {
    let start = allocate(data)
    let count = max(1, (data.count + Self.block - 1) / Self.block)
    inode(
      n, mode: 0x81A4, size: data.count, flags: 0x80000, block: Self.extents([(0, count, start)]))
  }

  mutating func directory(_ n: Int, parent: Int, _ entries: [(String, Int, Int)]) {
    var d = Data(count: Self.block)
    var offset = 0
    let all = [(".", n, 2), ("..", parent, 2)] + entries
    for (i, entry) in all.enumerated() {
      let name = Data(entry.0.utf8)
      let length = i == all.count - 1 ? Self.block - offset : (8 + name.count + 3) / 4 * 4
      for k in 0..<4 { d[offset + k] = UInt8(entry.1 >> (8 * k) & 0xff) }
      d[offset + 4] = UInt8(length & 0xff)
      d[offset + 5] = UInt8(length >> 8)
      d[offset + 6] = UInt8(name.count)
      d[offset + 7] = UInt8(entry.2)
      d.replaceSubrange(offset + 8..<offset + 8 + name.count, with: name)
      offset += length
    }
    let start = allocate(d)
    inode(n, mode: 0x41ED, size: Self.block, flags: 0x80000, block: Self.extents([(0, 1, start)]))
  }

  static func build() -> Data {
    var f = Ext4Fixture()
    let sb = 1024
    f.put32(32, sb + 0)  // inodes
    f.put32(blocks, sb + 4)
    f.put32(1, sb + 20)  // first data block
    f.put32(0, sb + 24)  // 1 KB blocks
    f.put32(32, sb + 40)  // inodes per group
    f.put16(0xEF53, sb + 56)
    f.put32(1, sb + 76)  // dynamic revision
    f.put16(256, sb + 88)
    f.put32(0x40, sb + 96)  // extents
    f.put32(4, 2 * block + 8)  // inode table at block 4

    f.directory(
      2, parent: 2, [("boot", 12, 2), ("vmlinuz", 13, 7), ("longlink", 19, 7)])
    f.directory(
      12, parent: 2,
      [
        ("vmlinuz-6.9.0", 14, 1), ("vmlinuz-6.10.0", 15, 1), ("initrd.img-6.10.0", 16, 1),
        ("System.map-6.10.0", 17, 1), ("config-6.10.0", 18, 1),
      ])
    let fast = Data("boot/vmlinuz-6.10.0".utf8)
    f.inode(13, mode: 0xA1FF, size: fast.count, flags: 0, block: fast)
    f.file(14, Data("old".utf8))
    // The kernel: blocks 0 and 2 mapped, block 1 a hole.
    let a = f.allocate(kernel.prefix(1024))
    let c = f.allocate(kernel.suffix(1024))
    f.inode(
      15, mode: 0x81A4, size: kernel.count, flags: 0x80000,
      block: extents([(0, 1, a), (2, 1, c)]))
    // The initrd: block-mapped (no extents flag), two direct blocks.
    let i = f.allocate(initrd)
    var map = Data(count: 60)
    for (slot, blockNumber) in [i, i + 1].enumerated() {
      for k in 0..<4 { map[slot * 4 + k] = UInt8(blockNumber >> (8 * k) & 0xff) }
    }
    f.inode(16, mode: 0x81A4, size: initrd.count, flags: 0, block: map)
    f.file(17, systemMap)
    // The config: a depth-1 tree, its leaf in a block of its own.
    let data = f.allocate(config)
    let leaf = f.allocate(extents([(0, 1, data)], size: block))
    f.inode(
      18, mode: 0x81A4, size: config.count, flags: 0x80000, block: extents([(0, 0, leaf)], depth: 1)
    )
    let slow = f.allocate(Data(longTarget.utf8))
    f.inode(
      19, mode: 0xA1FF, size: longTarget.utf8.count, flags: 0x80000,
      block: extents([(0, 1, slow)]))

    // GPT: protective space, header at LBA 1, entries at LBA 2, the partition at LBA 64.
    var disk = Data(count: partitionLBA * 512)
    disk.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
    func p32(_ v: Int, _ at: Int) { for k in 0..<4 { disk[at + k] = UInt8(v >> (8 * k) & 0xff) } }
    p32(2, 512 + 72)
    p32(4, 512 + 80)
    p32(128, 512 + 84)
    disk[1024] = 0xAF  // a non-zero type GUID
    p32(partitionLBA, 1024 + 32)
    p32(partitionLBA + blocks * 2 - 1, 1024 + 40)
    return disk + f.fs
  }
}

@Suite struct Ext4Tests {
  static func image() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vmlab-ext4-\(UUID()).raw")
    try Ext4Fixture.build().write(to: url)
    return url
  }

  @Test func readsPartitionsAndFiles() throws {
    let url = try Self.image()
    defer { try? FileManager.default.removeItem(at: url) }
    let partitions = try Ext4Volume.partitions(of: url)
    #expect(partitions.map(\.index) == [1])
    #expect(partitions.first?.offset == UInt64(Ext4Fixture.partitionLBA * 512))
    let volume = try Ext4Volume(image: url, offset: partitions[0].offset)

    let root = try volume.lookup("/")
    #expect(try volume.entries(of: root).map(\.name) == ["boot", "vmlinuz", "longlink"])
    // A fast symlink, followed; the extent file reads its hole as zeros.
    let kernel = try volume.lookup("/vmlinuz")
    #expect(kernel.kind == .file)
    #expect(try volume.contents(of: kernel) == Ext4Fixture.kernel)
    #expect(try volume.readLink(volume.lookup("/vmlinuz", follow: false)) == "boot/vmlinuz-6.10.0")
    #expect(
      try volume.readLink(volume.lookup("/longlink", follow: false)) == Ext4Fixture.longTarget)
    #expect(try volume.contents(of: volume.lookup("/boot/initrd.img-6.10.0")) == Ext4Fixture.initrd)
    #expect(try volume.contents(of: volume.lookup("/boot/config-6.10.0")) == Ext4Fixture.config)
    #expect(
      try volume.contents(of: volume.lookup("/boot/../boot/./vmlinuz-6.9.0")) == Data("old".utf8))

    let copy = url.deletingPathExtension().appendingPathExtension("kernel")
    defer { try? FileManager.default.removeItem(at: copy) }
    try volume.copy(kernel, to: copy)
    #expect(try Data(contentsOf: copy) == Ext4Fixture.kernel)

    #expect(throws: VMLabError.self) { try volume.lookup("/boot/missing") }
    #expect(throws: VMLabError.self) { try Ext4Volume(image: url, offset: 0) }
  }

  /// CX-8: a crafted image is an `engine_error`, never a trap: zero or overshifted geometry,
  /// offsets that overflow, sizes past what a file may hold, GPT fields that overflow.
  @Test func craftedGeometryIsAnErrorNotACrash() throws {
    let fs = Ext4Fixture.partitionLBA * 512
    let sb = fs + 1024
    func patched(_ edits: (inout Data) -> Void) throws -> URL {
      var disk = Ext4Fixture.build()
      edits(&disk)
      let url = FileManager.default.temporaryDirectory.appending(path: "vmlab-ext4-\(UUID()).raw")
      try disk.write(to: url)
      return url
    }
    func put(_ disk: inout Data, _ value: UInt64, _ at: Int, _ width: Int) {
      for k in 0..<width { disk[at + k] = UInt8(value >> (8 * UInt64(k)) & 0xff) }
    }
    func refused(_ body: () throws -> Void) {
      let error = #expect(throws: VMLabError.self) { try body() }
      #expect(error?.code == .engineError)
    }
    let offset = UInt64(fs)

    for edit in [
      { (d: inout Data) in put(&d, 0, sb + 40, 4) },  // inodes per group 0
      { (d: inout Data) in put(&d, 60, sb + 24, 4) },  // block size 1024 << 60
      { (d: inout Data) in put(&d, 0, sb + 88, 2) },  // inode size 0
      { (d: inout Data) in put(&d, 4096, sb + 88, 2) },  // inode size past the block
    ] {
      let url = try patched(edit)
      defer { try? FileManager.default.removeItem(at: url) }
      refused { _ = try Ext4Volume(image: url, offset: offset) }
    }

    let image = try Self.image()
    defer { try? FileManager.default.removeItem(at: image) }
    refused { _ = try Ext4Volume(image: image, offset: UInt64.max - 100) }

    // A 64-bit descriptor whose inode table lies past 2^64 bytes.
    let far = try patched {
      put(&$0, 0xC0, sb + 96, 4)
      put(&$0, 64, sb + 254, 2)
      put(&$0, 0xFFFF_FFFF, fs + 2 * 1024 + 0x28, 4)
    }
    defer { try? FileManager.default.removeItem(at: far) }
    refused { _ = try Ext4Volume(image: far, offset: offset).lookup("/") }

    // A kernel inode claiming 2^64 - 1 bytes.
    let huge = try patched {
      let inode = fs + 4 * 1024 + 14 * 256
      put(&$0, 0xFFFF_FFFF, inode + 4, 4)
      put(&$0, 0xFFFF_FFFF, inode + 0x6C, 4)
    }
    defer { try? FileManager.default.removeItem(at: huge) }
    let volume = try Ext4Volume(image: huge, offset: offset)
    let kernel = try volume.lookup("/boot/vmlinuz-6.10.0")
    refused { _ = try volume.contents(of: kernel) }
    let out = huge.appendingPathExtension("out")
    defer { try? FileManager.default.removeItem(at: out) }
    refused { try volume.copy(kernel, to: out) }

    // GPT: an entry table LBA past 2^64 bytes; a partition whose range overflows is skipped.
    let table = try patched { put(&$0, UInt64.max, 512 + 72, 8) }
    defer { try? FileManager.default.removeItem(at: table) }
    refused { _ = try Ext4Volume.partitions(of: table) }
    let range = try patched { put(&$0, UInt64.max / 2, 1024 + 40, 8) }
    defer { try? FileManager.default.removeItem(at: range) }
    #expect(try Ext4Volume.partitions(of: range).isEmpty)
  }

  @Test func extractKernelTakesTheNewestVersion() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-kernel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = ImageStore(home: home)
    let folder = store.imageDirectory("tiny")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Ext4Fixture.build().write(to: folder.appending(path: "disk.raw"))
    let record = PulledImage(
      name: "tiny", guest: GuestSpec(os: .linux, arch: .arm64), source: "test", format: .raw,
      checksum: nil, files: ["raw": "disk.raw"], login: ImageLogin(user: "debian"),
      pulledAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: folder.appending(path: "image.json"))

    let files = try await store.extractKernel("tiny")
    #expect(files.version == "6.10.0")
    #expect(try Data(contentsOf: files.kernel) == Ext4Fixture.kernel)
    #expect(try files.initrd.map { try Data(contentsOf: $0) } == Ext4Fixture.initrd)
    #expect(try files.systemMap.map { try Data(contentsOf: $0) } == Ext4Fixture.systemMap)
    #expect(try files.config.map { try Data(contentsOf: $0) } == Ext4Fixture.config)
    #expect(store.kernel(of: "tiny") == files)
    #expect(store.pulled("tiny")?.files["kernel"] == "kernel/vmlinuz")
    #expect(store.pulled("tiny")?.files["raw"] == "disk.raw")

    let missing = await #expect(throws: VMLabError.self) { try await store.extractKernel("nope") }
    #expect(missing?.code == .imageNotFound)
  }

  @Test func registerKernelRecordsAKernelOnlyImage() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-kernel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let kernel = home.appending(path: "Image")
    let initrd = home.appending(path: "rootfs.cpio")
    try Data("kernel".utf8).write(to: kernel)
    try Data("initrd".utf8).write(to: initrd)
    let store = ImageStore(home: home)

    let files = try await store.registerKernel(
      "mykernel", kernel: kernel, initrd: initrd, guest: GuestSpec(os: .linux, arch: .riscv64))
    #expect(try Data(contentsOf: files.kernel) == Data("kernel".utf8))
    #expect(files.initrd?.lastPathComponent == "initrd.img")
    let record = try #require(store.pulled("mykernel"))
    #expect(record.format == .kernel)
    #expect(record.guest.arch == .riscv64)
    #expect(record.files == ["kernel": "kernel/vmlinuz", "initrd": "kernel/initrd.img"])
    #expect(store.list().contains { $0.name == "mykernel" })

    let bad = await #expect(throws: VMLabError.self) {
      try await store.registerKernel("x", kernel: home.appending(path: "none"))
    }
    #expect(bad?.code == .invalidRequest)
  }

  /// A re-registration that fails part-way keeps the kernel already registered, and leaves no
  /// temporary file: the new copy is renamed over the old one, never deleted first.
  @Test func aFailedReRegistrationKeepsTheOldKernel() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-kernel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let kernel = home.appending(path: "Image")
    try Data("kernel".utf8).write(to: kernel)
    let store = ImageStore(home: home)
    let files = try await store.registerKernel("k", kernel: kernel)
    let unreadable = home.appending(path: "Image2")
    try Data("other".utf8).write(to: unreadable)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
    }
    await #expect(throws: (any Error).self) {
      try await store.registerKernel("k", kernel: unreadable)
    }
    #expect(try Data(contentsOf: files.kernel) == Data("kernel".utf8))
    let left = try FileManager.default.contentsOfDirectory(
      atPath: files.kernel.deletingLastPathComponent().path)
    #expect(left == ["vmlinuz"])
  }

  /// R-604: a gzip kernel (`Image.gz`) is stored uncompressed for `VZLinuxBootLoader`.
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: GzipTests.gzip)))
  func registerKernelDecompressesAGzipKernel() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-kernel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let kernel = home.appending(path: "Image.gz")
    try await GzipTests.compressed(GzipTests.payload, name: "Image").write(to: kernel)
    let files = try await ImageStore(home: home).registerKernel("gz", kernel: kernel)
    #expect(try Data(contentsOf: files.kernel) == GzipTests.payload)
  }

  /// A kernel boot without a kernel path takes the image's kernel and initrd; paths are checked.
  @Test func resolvingBootFillsTheImageKernel() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-kernel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let kernel = home.appending(path: "Image")
    let initrd = home.appending(path: "initrd")
    try Data("kernel".utf8).write(to: kernel)
    try Data("initrd".utf8).write(to: initrd)
    let store = ImageStore(home: home)
    let files = try await store.registerKernel("k", kernel: kernel, initrd: initrd)

    let boot = try await store.resolvingBoot(
      BootSpec(mode: .kernel, cmdline: "console=hvc0"), image: "k")
    #expect(boot.kernel == files.kernel.path && boot.initrd == files.initrd?.path)
    #expect(boot.cmdline == "console=hvc0")
    #expect(try await store.resolvingBoot(nil, image: nil) == BootSpec())
    let noImage = await #expect(throws: VMLabError.self) {
      try await store.resolvingBoot(BootSpec(mode: .kernel), image: nil)
    }
    #expect(noImage?.data["field"] == .string("boot.kernel"))
    let missing = await #expect(throws: VMLabError.self) {
      try await store.resolvingBoot(BootSpec(mode: .kernel, kernel: "/no/such/Image"), image: nil)
    }
    #expect(missing?.code == .invalidRequest)
  }
}
