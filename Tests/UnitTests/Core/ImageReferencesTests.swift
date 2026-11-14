import Foundation
import Testing

@testable import VMLabCore

/// What a model-named disk image points at, read from its header before QEMU or qemu-img opens
/// anything: a backing file or an external data file may be any host file or a network address.
@Suite struct ImageReferencesTests {
  /// A qcow2 header (version 3 unless `version` says 2) naming `backing` and `dataFile`.
  static func qcow2(backing: String? = nil, dataFile: String? = nil, version: UInt32 = 3) -> Data {
    func be(_ value: UInt64, _ width: Int) -> [UInt8] {
      (0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
    let headerLength = version == 3 ? 112 : 72
    var extensions: [UInt8] = []
    if let dataFile {
      let name = Array(dataFile.utf8)
      extensions += be(0x4441_5441, 4) + be(UInt64(name.count), 4) + name
      extensions += [UInt8](repeating: 0, count: (8 - name.count % 8) % 8)
    }
    extensions += [UInt8](repeating: 0, count: 8)
    let backingOffset = backing == nil ? 0 : headerLength + extensions.count
    var header = [0x51, 0x46, 0x49, 0xFB] + be(UInt64(version), 4)
    header += be(UInt64(backingOffset), 8) + be(UInt64(backing?.utf8.count ?? 0), 4)
    header += [UInt8](repeating: 0, count: 72 - header.count)
    if version == 3 {
      header += be(dataFile == nil ? 0 : 0b100, 8) + [UInt8](repeating: 0, count: 20)
      header += be(UInt64(headerLength), 4) + [UInt8](repeating: 0, count: 8)
    }
    return Data(header + extensions + Array((backing ?? "").utf8))
      + Data(count: 4096)
  }

  @Test func aQcow2HeaderGivesUpItsNames() {
    #expect(ImageReferences.scan(Self.qcow2()) == .qcow2(.init()))
    #expect(ImageReferences.scan(Self.qcow2(version: 2)) == .qcow2(.init()))
    for name in ["base.qcow2", "/Users/me/.ssh/id_ed25519", "nbd://127.0.0.1:5432/x"] {
      #expect(ImageReferences.scan(Self.qcow2(backing: name)) == .qcow2(.init(backing: name)))
      #expect(
        ImageReferences.scan(Self.qcow2(backing: name, version: 2))
          == .qcow2(.init(backing: name)))
      #expect(ImageReferences.scan(Self.qcow2(dataFile: name)) == .qcow2(.init(dataFile: name)))
    }
    #expect(
      ImageReferences.scan(Self.qcow2(backing: "b", dataFile: "json:{}"))
        == .qcow2(.init(backing: "b", dataFile: "json:{}")))
  }

  /// A header that does not parse is not waved through as a qcow2 without references.
  @Test func anUnreadableQcow2AndOtherContainersAreOpaque() {
    func isOpaque(_ data: Data) -> Bool {
      if case .opaque = ImageReferences.scan(data) { return true }
      return false
    }
    #expect(isOpaque(Data([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3])))
    var beyond = Self.qcow2(backing: "x")
    beyond.replaceSubrange(8..<16, with: [0, 0, 0, 0, 0x7F, 0, 0, 0])
    #expect(isOpaque(beyond))
    // Offsets no file has, with and without a size: refused, not trapped on.
    for version: UInt32 in [2, 3] {
      for size: UInt8 in [0, 4] {
        var huge = Self.qcow2(version: version)
        huge.replaceSubrange(8..<16, with: [UInt8](repeating: 0xFF, count: 8))
        huge[19] = size
        #expect(isOpaque(huge))
      }
    }
    var lengths = Self.qcow2(dataFile: "x")
    lengths.replaceSubrange(116..<120, with: [0xFF, 0xFF, 0xFF, 0xFF])  // the extension's length
    #expect(isOpaque(lengths))
    var claimed = Self.qcow2()
    claimed[79] = 0b100  // says it has an external data file, names none
    #expect(isOpaque(claimed))
    for magic in ["KDMV", "QED\0", "vhdxfile", "WithoutFreeSpace"] {
      #expect(isOpaque(Data(magic.utf8) + Data(count: 512)))
    }
    #expect(isOpaque(Data("# Disk DescriptorFile\nversion=1\n".utf8)))
    #expect(ImageReferences.scan(Data(count: 4096)) == .plain)
    #expect(ImageReferences.scan(Data("just some bytes".utf8)) == .plain)
    #expect(ImageReferences.scan(Data()) == .plain)
  }

  /// QEMU's own test: a colon before any slash is a protocol.
  @Test func namesThatAreNotFilePaths() {
    for name in ["/a/b.qcow2", "base.qcow2", "../base.qcow2", "dir/with:colon"] {
      #expect(ImageReferences.isLocalPath(name), "\(name)")
    }
    for name in [
      "nbd://127.0.0.1:5432/x", "http://10.0.0.1/secret", "json:{\"driver\":\"nbd\"}",
      "nbd:unix:/tmp/s", "fat:/etc", "file:/etc/passwd", "",
    ] {
      #expect(!ImageReferences.isLocalPath(name), "\(name)")
    }
    let image = URL(filePath: "/tmp/images/top.qcow2")
    #expect(ImageReferences.resolve("base.qcow2", from: image) == "/tmp/images/base.qcow2")
    #expect(ImageReferences.resolve("/abs/base", from: image) == "/abs/base")
  }
}
