import Foundation

/// gzip (RFC 1952) decoding with Foundation's raw-DEFLATE decompressor, for kernels shipped as
/// `Image.gz`: Virtualization.framework's `VZLinuxBootLoader` takes only an uncompressed arm64
/// `Image`, so registration stores kernels uncompressed (R-604).
public enum Gzip {
  /// Whether `data` starts with the gzip magic and the DEFLATE method.
  public static func isGzip(_ data: Data) -> Bool {
    data.count >= 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
      && data[data.startIndex + 2] == 8
  }

  /// The first member of a gzip stream, decompressed.
  public static func decompress(_ data: Data) throws(VMLabError) -> Data {
    let bytes = [UInt8](data)
    guard isGzip(data) else { throw corrupt("not a gzip stream") }
    let flags = bytes[3]
    var index = 10
    if flags & 0x04 != 0 {  // FEXTRA
      guard index + 2 <= bytes.count else { throw corrupt("truncated extra field") }
      index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
    }
    for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {  // FNAME, FCOMMENT
      while index < bytes.count, bytes[index] != 0 { index += 1 }
      index += 1
    }
    if flags & 0x02 != 0 { index += 2 }  // FHCRC
    guard index < bytes.count - 8 else { throw corrupt("truncated header") }
    let payload = Data(bytes[index..<(bytes.count - 8)])
    let expected = bytes.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
    let output: Data
    do {
      output = try (payload as NSData).decompressed(using: .zlib) as Data
    } catch {
      throw corrupt("\(error.localizedDescription)")
    }
    guard output.count & 0xFFFF_FFFF == expected else {
      throw corrupt("decompressed \(output.count) bytes, the trailer says \(expected)")
    }
    return output
  }

  /// Replaces a gzip file at `url` with its decompressed contents; any other file is left as is.
  public static func decompressInPlace(_ url: URL) throws(VMLabError) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    let head = (try? handle.read(upToCount: 18)) ?? Data()
    try? handle.close()
    guard isGzip(head) else { return }
    do {
      let data = try Data(contentsOf: url)
      try decompress(data).write(to: url, options: .atomic)
    } catch let error as VMLabError {
      throw error
    } catch {
      throw VMLabError(
        code: .internal, message: "Cannot rewrite \(url.path) uncompressed: \(error)",
        hint: "Check free disk space under VMLAB_HOME.", data: ["path": .string(url.path)])
    }
  }

  private static func corrupt(_ reason: String) -> VMLabError {
    .invalidRequest(
      field: "kernel", reason: "the gzip kernel cannot be decompressed: \(reason)",
      hint: "Give an uncompressed arm64 Image, or a valid Image.gz.")
  }
}
