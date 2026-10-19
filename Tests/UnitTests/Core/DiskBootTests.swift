import Foundation
import Testing

@testable import VMLabCore

/// A disk like a Debian cloud image's, on `Ext4Fixture`'s geometry: `/boot` with two kernels
/// (6.1.0 and the newer 6.10.0) and their initrds, `/boot/grub/grub.cfg` when given,
/// `/boot/vmlinuz` and `/boot/initrd.img` links to 6.1.0 when asked, `/etc/fstab` and
/// `/etc/default/grub`.
enum DiskBootFixture {
  /// An arm64 `Image`: `ARM\x64` at byte 56.
  static let image: Data = {
    var data = Data((0..<2048).map { UInt8($0 % 199) })
    data.replaceSubrange(56..<60, with: Data("ARM\u{64}".utf8))
    return data
  }()
  static let oldImage: Data = {
    var data = image
    data[0] = 0xEE
    return data
  }()
  static let initrd = Data(repeating: 0x5A, count: 1500)
  static let oldInitrd = Data(repeating: 0x33, count: 700)
  static let fstab =
    "PARTUUID=0a0b / ext4 rw,discard 0 1\nPARTUUID=0c0d /boot/efi vfat defaults 0 2\n"
  static let defaults =
    "GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\nGRUB_CMDLINE_LINUX=\"net.ifnames=0\"\n"
  static let grub = """
    if [ "${next_entry}" ] ; then
       set default="${next_entry}"
    else
       set default="0"
    fi
    function savedefault {
      saved_entry="${chosen}"
    }
    menuentry 'Debian GNU/Linux' --class debian $menuentry_id_option 'gnulinux-simple-x' {
    \tinsmod ext2
    \tif [ x$feature_platform_search_hint = xy ]; then
    \t  search --no-floppy --fs-uuid --set=root abc
    \tfi
    \tlinux\t/boot/vmlinuz-6.10.0 root=PARTUUID=0a0b ro  console=tty0 $vt_handoff
    \tinitrd\t/boot/initrd.img-6.10.0
    }
    submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-x' {
    \tmenuentry 'Debian, with Linux 6.1.0' $menuentry_id_option 'gnulinux-6.1.0-advanced-x' {
    \t\tlinux\t/boot/vmlinuz-6.1.0 root=PARTUUID=0a0b ro
    \t\tinitrd\t/boot/initrd.img-6.1.0
    \t}
    }

    """

  static func build(
    grub: String? = Self.grub, kernel: Data = image, links: Bool = false
  ) -> Data {
    var f = Ext4Fixture()
    f.superblock()
    f.directory(2, parent: 2, [("boot", 12, 2), ("etc", 14, 2)])
    var boot: [(String, Int, Int)] = [
      ("vmlinuz-6.1.0", 16, 1), ("vmlinuz-6.10.0", 17, 1), ("initrd.img-6.10.0", 18, 1),
      ("initrd.img-6.1.0", 24, 1),
    ]
    if grub != nil { boot.append(("grub", 13, 2)) }
    if links { boot += [("vmlinuz", 22, 7), ("initrd.img", 23, 7)] }
    f.directory(12, parent: 2, boot)
    if let grub {
      f.directory(13, parent: 12, [("grub.cfg", 19, 1)])
      f.file(19, Data(grub.utf8))
    }
    f.directory(14, parent: 2, [("fstab", 20, 1), ("default", 15, 2)])
    f.directory(15, parent: 14, [("grub", 21, 1)])
    f.file(16, oldImage)
    f.file(17, kernel)
    f.file(18, initrd)
    f.file(24, oldInitrd)
    f.file(20, Data(fstab.utf8))
    f.file(21, Data(defaults.utf8))
    for (inode, target) in [(22, "vmlinuz-6.1.0"), (23, "initrd.img-6.1.0")] where links {
      let bytes = Data(target.utf8)
      f.inode(inode, mode: 0xA1FF, size: bytes.count, flags: 0, block: bytes)
    }
    return Ext4Fixture.disk(f.fs)
  }

  /// Byte offset of inode `n`'s `i_mtime` in a built disk.
  static func mtimeOffset(of n: Int) -> Int {
    Ext4Fixture.partitionLBA * 512 + 4 * Ext4Fixture.block + (n - 1) * 256 + 0x10
  }
}

@Suite struct DiskBootTests {
  static func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vmlab-diskboot-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func grubDefaultEntryIsTheFirstUnlessSetLiterally() throws {
    let entry = try #require(GrubConfig.defaultEntry(DiskBootFixture.grub))
    #expect(entry.kernel == "/boot/vmlinuz-6.10.0")
    #expect(entry.initrds == ["/boot/initrd.img-6.10.0"])
    // `$vt_handoff` is GRUB's to expand, not the kernel's.
    #expect(entry.arguments == ["root=PARTUUID=0a0b", "ro", "console=tty0"])

    for chosen in ["1>0", "gnulinux-advanced-x>gnulinux-6.1.0-advanced-x", "Advanced options"] {
      let text = DiskBootFixture.grub + "set default=\"\(chosen)\"\n"
      #expect(GrubConfig.defaultEntry(text)?.kernel == "/boot/vmlinuz-6.1.0", "\(chosen)")
    }
    // A default that names nothing boots the first entry, as GRUB does.
    #expect(
      GrubConfig.defaultEntry(DiskBootFixture.grub + "set default='nope'\n")?.kernel
        == "/boot/vmlinuz-6.10.0")
    #expect(GrubConfig.defaultEntry("menuentry 'UEFI Firmware Settings' {\n fwsetup\n}\n") == nil)
  }

  /// Ubuntu's separate boot partition: paths relative to it, two consoles of its own.
  @Test func ubuntuEntryKeepsItsConsolesAndPutsHvc0Last() throws {
    let text = """
      menuentry 'Ubuntu' --class ubuntu $menuentry_id_option 'gnulinux-simple-da3e' {
      \trecordfail
      \tlinux\t/vmlinuz-6.8.0-147-generic root=LABEL=cloudimg-rootfs ro  console=tty1 console=ttyAMA0
      \tinitrd\t/initrd.img-6.8.0-147-generic
      }
      """
    let entry = try #require(GrubConfig.defaultEntry(text))
    #expect(entry.kernel == "/vmlinuz-6.8.0-147-generic")
    #expect(
      DiskBoot.commandLine(entry.arguments)
        == "root=LABEL=cloudimg-rootfs ro console=tty1 console=ttyAMA0 console=hvc0")
  }

  @Test func hvc0IsMovedLastOnce() {
    #expect(
      DiskBoot.commandLine(["console=hvc0", "root=/dev/vda1", "console=tty0", "console=hvc0"])
        == "root=/dev/vda1 console=tty0 console=hvc0")
    #expect(DiskBoot.commandLine([]) == "console=hvc0")
  }

  @Test func etcDefaultGrubAndFstab() {
    let args = GrubConfig.defaultArguments([
      DiskBootFixture.defaults,
      "GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE_LINUX console=hvc0\"\nGRUB_CMDLINE_LINUX_DEFAULT=''\n",
    ])
    #expect(args == ["net.ifnames=0", "console=hvc0"])
    #expect(GrubConfig.rootSpec("# c\nUUID=1 /boot ext4\nLABEL=r\t/\text4 x 0 1\n") == "LABEL=r")
    #expect(GrubConfig.rootSpec("") == nil)
  }

  /// grub.cfg's default entry is staged once; an unchanged disk reuses the cache, a changed
  /// kernel (its mtime) refreshes it.
  @Test func stagesTheGrubDefaultAndReusesTheCache() throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let disk = dir.appending(path: "disk.raw")
    try DiskBootFixture.build().write(to: disk)
    let cache = dir.appending(path: DiskBoot.cacheDirectory)

    let first = try DiskBoot.stage(disk: disk, cache: cache)
    #expect(first.refreshed)
    #expect(first.entry.source == "/boot/grub/grub.cfg")
    #expect(first.entry.kernel == "/boot/vmlinuz-6.10.0")
    #expect(first.commandLine == "root=PARTUUID=0a0b ro console=tty0 console=hvc0")
    #expect(first.kernel == cache.appending(path: "vmlinuz").path)
    #expect(try Data(contentsOf: URL(filePath: first.kernel)) == DiskBootFixture.image)
    #expect(
      try first.initrd.map { try Data(contentsOf: URL(filePath: $0)) } == DiskBootFixture.initrd)

    let again = try DiskBoot.stage(disk: disk, cache: cache)
    #expect(!again.refreshed)
    #expect(again.kernel == first.kernel && again.commandLine == first.commandLine)

    // The guest touched its kernel.
    let handle = try FileHandle(forWritingTo: disk)
    try handle.seek(toOffset: UInt64(DiskBootFixture.mtimeOffset(of: 17)))
    try handle.write(contentsOf: Data([1, 2, 3, 4]))
    try handle.close()
    #expect(try DiskBoot.stage(disk: disk, cache: cache).refreshed)
    #expect(try !DiskBoot.stage(disk: disk, cache: cache).refreshed)
    // A cache whose files went missing is staged again.
    try FileManager.default.removeItem(atPath: first.kernel)
    #expect(try DiskBoot.stage(disk: disk, cache: cache).refreshed)
  }

  /// No grub.cfg: the `/boot/vmlinuz` link wins over the newest version; without links the
  /// newest is taken; the command line is `/etc/default/grub`'s with fstab's root.
  @Test func withoutGrubTheLinksThenTheNewestKernel() throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let disk = dir.appending(path: "disk.raw")

    try DiskBootFixture.build(grub: nil, links: true).write(to: disk)
    let linked = try DiskBoot.stage(disk: disk, cache: dir.appending(path: "a"))
    #expect(linked.entry.source == "/boot")
    #expect(linked.entry.kernel == "/boot/vmlinuz-6.1.0")
    #expect(linked.entry.initrds == ["/boot/initrd.img-6.1.0"])
    #expect(try Data(contentsOf: URL(filePath: linked.kernel)) == DiskBootFixture.oldImage)
    #expect(linked.commandLine == "root=PARTUUID=0a0b ro net.ifnames=0 quiet console=hvc0")

    try DiskBootFixture.build(grub: nil).write(to: disk)
    let newest = try DiskBoot.stage(disk: disk, cache: dir.appending(path: "b"))
    #expect(newest.entry.kernel == "/boot/vmlinuz-6.10.0")
    #expect(
      try newest.initrd.map { try Data(contentsOf: URL(filePath: $0)) } == DiskBootFixture.initrd)
  }

  /// VZ boots only an arm64 `Image`: a gzip one is decompressed into the cache.
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: GzipTests.gzip)))
  func aGzipKernelIsStagedUncompressed() async throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let disk = dir.appending(path: "disk.raw")
    let packed = try await GzipTests.compressed(DiskBootFixture.image, name: "Image")
    try DiskBootFixture.build(kernel: packed).write(to: disk)
    let staged = try DiskBoot.stage(disk: disk, cache: dir.appending(path: "cache"))
    #expect(try Data(contentsOf: URL(filePath: staged.kernel)) == DiskBootFixture.image)
  }

  /// What sends the guest back to EFI: no ext4, a kernel VZ cannot boot, a default entry
  /// whose kernel is not on the disk. A failed staging leaves no manifest behind.
  @Test func unreadableBootsAreEngineErrors() throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let disk = dir.appending(path: "disk.raw")
    let cache = dir.appending(path: "cache")
    func refused(_ reason: String) {
      let error = #expect(throws: VMLabError.self) { try DiskBoot.stage(disk: disk, cache: cache) }
      #expect(error?.code == .engineError)
      #expect(error?.message.contains(reason) == true, "\(error?.message ?? "")")
    }

    try Data(count: 1 << 16).write(to: disk)
    refused("no ext4 file system")

    var zboot = DiskBootFixture.image
    zboot.replaceSubrange(56..<60, with: Data(count: 4))
    try DiskBootFixture.build(kernel: zboot).write(to: disk)
    refused("not an arm64 Image")
    #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "boot.json").path))

    try DiskBootFixture.build(
      grub: DiskBootFixture.grub.replacingOccurrences(
        of: "vmlinuz-6.10.0", with: "vmlinuz-9")
    ).write(to: disk)
    refused("vmlinuz-9")
  }
}
