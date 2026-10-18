import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The guest screen as BGRX pixels (4 bytes per pixel, rows top to bottom, no row padding).
public struct Framebuffer: Equatable, Sendable {
  public private(set) var width: Int
  public private(set) var height: Int
  public private(set) var pixels: [UInt8]

  /// The largest edge accepted from a server; larger sizes are a protocol violation.
  public static let maxEdge = 8192
  /// The most pixels accepted from a server (128 MiB of BGRX; 8K UHD is 33,177,600). The guest
  /// picks the size, so this bounds what one screen costs the host.
  public static let maxPixels = 1 << 25

  /// Whether a server may give the screen this size: each edge at most `maxEdge` and the area at
  /// most `maxPixels`. Zero is allowed (a display not yet initialised).
  public static func accepts(width: Int, height: Int) -> Bool {
    (0...maxEdge).contains(width) && (0...maxEdge).contains(height)
      && width * height <= maxPixels
  }

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
    pixels = [UInt8](repeating: 0, count: width * height * 4)
  }

  /// A framebuffer over existing BGRX `pixels` (`width × height × 4` bytes).
  init(width: Int, height: Int, pixels: [UInt8]) {
    precondition(pixels.count == width * height * 4)
    self.width = width
    self.height = height
    self.pixels = pixels
  }

  /// Resizes to `width` × `height` and clears to black (RFB leaves the contents undefined).
  public mutating func resize(width: Int, height: Int) {
    self = Framebuffer(width: width, height: height)
  }

  func contains(x: Int, y: Int, width w: Int, height h: Int) -> Bool {
    x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height
  }

  /// Copies BGRX `data` (w × h × 4 bytes) into the rectangle at (x, y).
  mutating func applyRaw(x: Int, y: Int, width w: Int, height h: Int, data: [UInt8]) {
    precondition(contains(x: x, y: y, width: w, height: h) && data.count == w * h * 4)
    let rowBytes = w * 4
    pixels.withUnsafeMutableBufferPointer { dst in
      data.withUnsafeBufferPointer { src in
        for row in 0..<h {
          let d = ((y + row) * width + x) * 4
          let s = row * rowBytes
          dst.baseAddress!.advanced(by: d).update(
            from: src.baseAddress!.advanced(by: s), count: rowBytes)
        }
      }
    }
  }

  /// Copies the w × h rectangle at (srcX, srcY) to (x, y); the regions may overlap. Rows move in
  /// place (bottom up when the block moves down), with no copy of the block.
  mutating func copyRect(srcX: Int, srcY: Int, x: Int, y: Int, width w: Int, height h: Int) {
    precondition(
      contains(x: srcX, y: srcY, width: w, height: h) && contains(x: x, y: y, width: w, height: h))
    let rowBytes = w * 4
    guard rowBytes > 0 else { return }
    let stride = width
    let rows: [Int] = y > srcY ? Array((0..<h).reversed()) : Array(0..<h)
    pixels.withUnsafeMutableBytes { buffer in
      for row in rows {
        let s = ((srcY + row) * stride + srcX) * 4
        let d = ((y + row) * stride + x) * 4
        memmove(buffer.baseAddress! + d, buffer.baseAddress! + s, rowBytes)
      }
    }
  }

  /// The framebuffer as an opaque sRGB image.
  public func cgImage() throws -> CGImage {
    guard width > 0, height > 0 else { throw RFBError.emptyFramebuffer }
    let info = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = Self.provider(for: pixels),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw RFBError.emptyFramebuffer }
    return image
  }

  /// A data provider that reads `pixels` in place: the image keeps the array alive, and no copy of
  /// the screen is made until CoreGraphics reads it.
  static func provider(for pixels: [UInt8]) -> CGDataProvider? {
    final class Box {
      let pixels: [UInt8]
      init(_ pixels: [UInt8]) { self.pixels = pixels }
    }
    var callbacks = CGDataProviderDirectCallbacks(
      version: 0, getBytePointer: nil, releaseBytePointer: nil,
      getBytesAtPosition: { info, buffer, position, count in
        let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
        let start = Int(position)
        let n = max(0, min(count, box.pixels.count - start))
        box.pixels.withUnsafeBytes { src in
          buffer.copyMemory(from: src.baseAddress! + start, byteCount: n)
        }
        return n
      },
      releaseInfo: { info in Unmanaged<Box>.fromOpaque(info!).release() })
    let info = Unmanaged.passRetained(Box(pixels)).toOpaque()
    guard
      let provider = CGDataProvider(
        directInfo: info, size: off_t(pixels.count), callbacks: &callbacks)
    else {
      Unmanaged<Box>.fromOpaque(info).release()
      return nil
    }
    return provider
  }

  /// The framebuffer encoded as PNG.
  public func pngData() throws -> Data {
    try Self.pngData(try cgImage())
  }

  /// Encodes any image as PNG with ImageIO.
  public static func pngData(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { throw RFBError.emptyFramebuffer }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw RFBError.emptyFramebuffer }
    return data as Data
  }
}
