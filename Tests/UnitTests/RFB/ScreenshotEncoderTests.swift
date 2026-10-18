import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import VMLabRFB

/// A synthetic screen filled with one BGRX colour, with helpers to paint rectangles.
func solidScreen(_ w: Int, _ h: Int, _ bgr: (UInt8, UInt8, UInt8) = (0, 0, 0)) -> Framebuffer {
  var fb = Framebuffer(width: w, height: h)
  fb.paint(PixelRect(x: 0, y: 0, width: w, height: h), bgr)
  return fb
}

extension Framebuffer {
  mutating func paint(_ r: PixelRect, _ bgr: (UInt8, UInt8, UInt8)) {
    var data = [UInt8](repeating: 0, count: r.width * r.height * 4)
    for i in stride(from: 0, to: data.count, by: 4) {
      data[i] = bgr.0
      data[i + 1] = bgr.1
      data[i + 2] = bgr.2
    }
    applyRaw(x: r.x, y: r.y, width: r.width, height: r.height, data: data)
  }
}

/// Decodes encoded image data; returns its size and the RGBA of its top-left pixel.
func decode(_ data: Data) throws -> (width: Int, height: Int, type: String, topLeft: [UInt8]) {
  let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  var pixel = [UInt8](repeating: 0, count: 4)
  let context = try #require(
    CGContext(
      data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.draw(
    image, in: CGRect(x: 0, y: 1 - image.height, width: image.width, height: image.height))
  return (image.width, image.height, CGImageSourceGetType(source)! as String, pixel)
}

@Suite struct ScreenshotEncoderTests {
  @Test func pngAtFullSizeWhenItFits() throws {
    let out = try ScreenshotEncoder.encode(solidScreen(64, 32, (0, 0, 255)))
    let d = try decode(out.data)
    #expect(out.scale == 1 && out.width == 64 && out.height == 32 && out.mimeType == "image/png")
    #expect(d.width == 64 && d.height == 32 && d.type == "public.png")
    #expect(d.topLeft == [255, 0, 0, 255])  // BGRX (0, 0, 255) is red
  }

  @Test func maxEdgeScalesTheLongEdgeAndReportsTheFactor() throws {
    let out = try ScreenshotEncoder.encode(
      solidScreen(2000, 1000), options: .init(maxEdge: 1280))
    #expect(out.scale == 0.64)
    #expect(out.width == 1280 && out.height == 640)
    let d = try decode(out.data)
    #expect(d.width == 1280 && d.height == 640)
  }

  @Test func nilMaxEdgeKeepsFullResolution() throws {
    let out = try ScreenshotEncoder.encode(solidScreen(2000, 10), options: .init(maxEdge: nil))
    #expect(out.scale == 1 && out.width == 2000)
  }

  @Test func jpegHonoursQuality() throws {
    var fb = solidScreen(256, 256)
    for i in 0..<64 {
      fb.paint(PixelRect(x: i * 4, y: (i * 37) % 250, width: 3, height: 6), (UInt8(i * 4), 90, 200))
    }
    let low = try ScreenshotEncoder.encode(fb, options: .init(format: .jpeg, quality: 5))
    let high = try ScreenshotEncoder.encode(fb, options: .init(format: .jpeg, quality: 100))
    #expect(try decode(low.data).type == "public.jpeg" && low.mimeType == "image/jpeg")
    #expect(low.data.count < high.data.count)
  }

  @Test func regionCropsInGuestPixelsAndIsClipped() throws {
    var fb = solidScreen(100, 100)
    fb.paint(PixelRect(x: 40, y: 10, width: 60, height: 90), (0, 255, 0))
    let out = try ScreenshotEncoder.encode(
      fb, options: .init(region: PixelRect(corners: 40, 10, 140, 60)))
    #expect(out.source == PixelRect(x: 40, y: 10, width: 60, height: 50))
    let d = try decode(out.data)
    #expect(d.width == 60 && d.height == 50 && d.topLeft == [0, 255, 0, 255])
  }

  @Test func scaleIsComputedOnTheRegion() throws {
    let out = try ScreenshotEncoder.encode(
      solidScreen(400, 400),
      options: .init(maxEdge: 100, region: PixelRect(x: 0, y: 0, width: 200, height: 50)))
    #expect(out.scale == 0.5 && out.width == 100 && out.height == 25)
  }

  @Test func badOptionsAreInvalidRequests() {
    let fb = solidScreen(10, 10)
    #expect(throws: RFBError.invalidScreenshotRequest(field: "quality", reason: "must be 1 to 100"))
    {
      try ScreenshotEncoder.encode(fb, options: .init(quality: 0))
    }
    #expect(
      throws: RFBError.invalidScreenshotRequest(field: "maxEdge", reason: "must be at least 1")
    ) {
      try ScreenshotEncoder.encode(fb, options: .init(maxEdge: 0))
    }
    #expect(throws: RFBError.self) {
      try ScreenshotEncoder.encode(
        fb, options: .init(region: PixelRect(x: 20, y: 20, width: 5, height: 5)))
    }
    #expect(throws: RFBError.emptyFramebuffer) {
      try ScreenshotEncoder.encode(Framebuffer(width: 0, height: 0))
    }
  }
}
