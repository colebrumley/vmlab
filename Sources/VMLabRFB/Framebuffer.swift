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
  public static let maxEdge = 16384

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

  /// Copies the w × h rectangle at (srcX, srcY) to (x, y); the regions may overlap.
  mutating func copyRect(srcX: Int, srcY: Int, x: Int, y: Int, width w: Int, height h: Int) {
    var block = [UInt8]()
    block.reserveCapacity(w * h * 4)
    for row in 0..<h {
      let s = ((srcY + row) * width + srcX) * 4
      block += pixels[s..<(s + w * 4)]
    }
    applyRaw(x: x, y: y, width: w, height: h, data: block)
  }

  /// The framebuffer as an opaque sRGB image.
  public func cgImage() throws -> CGImage {
    guard width > 0, height > 0 else { throw RFBError.emptyFramebuffer }
    let info = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw RFBError.emptyFramebuffer }
    return image
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
