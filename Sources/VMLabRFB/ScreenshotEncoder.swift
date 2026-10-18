import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A rectangle in guest pixels: origin at the top left, rows downward.
public struct PixelRect: Equatable, Hashable, Codable, Sendable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// The rectangle between corners `[x0, y0]` and `[x1, y1]` (exclusive), as tool arguments give it.
  /// Spans past `Int.max` saturate rather than trapping.
  public init(corners x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
    self.init(
      x: min(x0, x1), y: min(y0, y1), width: Self.gap(min(x0, x1), max(x0, x1)),
      height: Self.gap(min(y0, y1), max(y0, y1)))
  }

  public var isEmpty: Bool { width <= 0 || height <= 0 }

  /// The part of this rectangle inside `other`; empty when they do not overlap. Edges past
  /// `Int.max` saturate, so any coordinates are safe.
  public func intersection(_ other: PixelRect) -> PixelRect {
    let x0 = max(x, other.x)
    let y0 = max(y, other.y)
    let x1 = min(Self.end(x, width), Self.end(other.x, other.width))
    let y1 = min(Self.end(y, height), Self.end(other.y, other.height))
    return PixelRect(x: x0, y: y0, width: Self.gap(x0, x1), height: Self.gap(y0, y1))
  }

  /// `start + length`, saturating.
  private static func end(_ start: Int, _ length: Int) -> Int {
    let (sum, overflow) = start.addingReportingOverflow(length)
    return overflow ? (length > 0 ? .max : .min) : sum
  }

  /// `to - from` when positive, else 0, saturating at `Int.max`.
  private static func gap(_ from: Int, _ to: Int) -> Int {
    guard to > from else { return 0 }
    let (difference, overflow) = to.subtractingReportingOverflow(from)
    return overflow ? .max : difference
  }
}

/// The image encodings a screenshot can be returned in.
public enum ScreenshotFormat: String, Codable, Sendable, CaseIterable {
  case png
  case jpeg

  public var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
}

/// How a screenshot is cropped, scaled and encoded.
public struct ScreenshotOptions: Equatable, Sendable {
  /// The default long-edge limit (R-502).
  public static let defaultMaxEdge = 1280
  /// The default JPEG quality, 1 to 100.
  public static let defaultQuality = 80

  public var format: ScreenshotFormat
  /// JPEG quality from 1 (smallest) to 100 (best); ignored for PNG.
  public var quality: Int
  /// The longest edge of the returned image in pixels; `nil` keeps full resolution. Never upscales.
  public var maxEdge: Int?
  /// The part of the screen to return, in guest pixels; `nil` is the whole screen. Clipped to the
  /// screen.
  public var region: PixelRect?

  public init(
    format: ScreenshotFormat = .png, quality: Int = Self.defaultQuality,
    maxEdge: Int? = Self.defaultMaxEdge, region: PixelRect? = nil
  ) {
    self.format = format
    self.quality = quality
    self.maxEdge = maxEdge
    self.region = region
  }

  /// Checks the options against a screen of `width` × `height` and returns the clipped frame: the
  /// region, or the whole screen.
  public func frame(width: Int, height: Int) throws -> PixelRect {
    guard (1...100).contains(quality) else {
      throw RFBError.invalidScreenshotRequest(field: "quality", reason: "must be 1 to 100")
    }
    if let maxEdge, maxEdge < 1 {
      throw RFBError.invalidScreenshotRequest(field: "maxEdge", reason: "must be at least 1")
    }
    let screen = PixelRect(x: 0, y: 0, width: width, height: height)
    guard !screen.isEmpty else { throw RFBError.emptyFramebuffer }
    guard let region else { return screen }
    let clipped = region.intersection(screen)
    guard !clipped.isEmpty else {
      throw RFBError.invalidScreenshotRequest(
        field: "region", reason: "is empty or outside the \(width)x\(height) screen")
    }
    return clipped
  }

  /// The factor that brings `frame`'s long edge within `maxEdge`; 1 when it already fits.
  public func scale(for frame: PixelRect) -> Double {
    guard let maxEdge else { return 1 }
    let edge = max(frame.width, frame.height)
    return edge > maxEdge ? Double(maxEdge) / Double(edge) : 1
  }
}

/// An encoded image and the geometry needed to map its pixels back to the guest screen.
public struct EncodedImage: Equatable, Sendable {
  public var data: Data
  public var format: ScreenshotFormat
  /// The encoded image's size in pixels (after scaling).
  public var width: Int
  public var height: Int
  /// Image pixels per guest pixel: guest = origin + image / scale.
  public var scale: Double
  /// The guest rectangle the image shows.
  public var source: PixelRect

  public var mimeType: String { format.mimeType }
}

/// Crops, scales and encodes framebuffers with ImageIO and CoreGraphics.
public enum ScreenshotEncoder {
  /// Encodes `framebuffer` per `options`: the region (or whole screen), scaled to fit `maxEdge`.
  public static func encode(_ framebuffer: Framebuffer, options: ScreenshotOptions = .init())
    throws -> EncodedImage
  {
    let frame = try options.frame(width: framebuffer.width, height: framebuffer.height)
    return try encode(framebuffer, rect: frame, scale: options.scale(for: frame), options: options)
  }

  /// Encodes the guest rectangle `rect` (already inside the screen) at a given `scale`.
  public static func encode(
    _ framebuffer: Framebuffer, rect: PixelRect, scale: Double, options: ScreenshotOptions
  ) throws -> EncodedImage {
    let full = try framebuffer.cgImage()
    let bounds = PixelRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
    guard !rect.isEmpty, rect.intersection(bounds) == rect else {
      throw RFBError.invalidScreenshotRequest(field: "region", reason: "is outside the screen")
    }
    var image = full
    if rect != bounds {
      guard
        let cropped = full.cropping(
          to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
      else { throw RFBError.emptyFramebuffer }
      image = cropped
    }
    if scale < 1 {
      image = try scaled(image, to: scaledSize(rect, scale))
    }
    let data = try encodeImage(image, format: options.format, quality: options.quality)
    return EncodedImage(
      data: data, format: options.format, width: image.width, height: image.height, scale: scale,
      source: rect)
  }

  /// The pixel size of `rect` at `scale`, at least 1 × 1.
  public static func scaledSize(_ rect: PixelRect, _ scale: Double) -> (width: Int, height: Int) {
    (
      max(1, Int((Double(rect.width) * scale).rounded())),
      max(1, Int((Double(rect.height) * scale).rounded()))
    )
  }

  static func scaled(_ image: CGImage, to size: (width: Int, height: Int)) throws -> CGImage {
    let info = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: info.rawValue)
    else { throw RFBError.emptyFramebuffer }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    guard let result = context.makeImage() else { throw RFBError.emptyFramebuffer }
    return result
  }

  static func encodeImage(_ image: CGImage, format: ScreenshotFormat, quality: Int) throws -> Data {
    let type = format == .png ? UTType.png : UTType.jpeg
    let data = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(
        data as CFMutableData, type.identifier as CFString, 1, nil)
    else { throw RFBError.emptyFramebuffer }
    var properties: [CFString: Any] = [:]
    if format == .jpeg {
      properties[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100
    }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw RFBError.emptyFramebuffer }
    return data as Data
  }
}
