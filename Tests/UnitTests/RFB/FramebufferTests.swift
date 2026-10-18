import Foundation
import Testing

@testable import VMLabRFB

@Suite struct FramebufferTests {
  static func numbered(_ w: Int, _ h: Int) -> Framebuffer {
    var fb = Framebuffer(width: w, height: h)
    fb.applyRaw(
      x: 0, y: 0, width: w, height: h,
      data: (0..<(w * h)).flatMap { [UInt8($0), 0, 0, 0] })
    return fb
  }

  func firstBytes(_ fb: Framebuffer) -> [UInt8] {
    stride(from: 0, to: fb.pixels.count, by: 4).map { fb.pixels[$0] }
  }

  @Test func overlappingCopyRectMovesTheSourceBlock() {
    var fb = Self.numbered(3, 3)
    fb.copyRect(srcX: 0, srcY: 0, x: 1, y: 1, width: 2, height: 2)
    #expect(firstBytes(fb) == [0, 1, 2, 3, 0, 1, 6, 3, 4])
  }

  @Test func resizeClearsToBlack() {
    var fb = Self.numbered(2, 2)
    fb.resize(width: 3, height: 1)
    #expect(fb.width == 3 && fb.height == 1 && fb.pixels == [UInt8](repeating: 0, count: 12))
  }

  @Test func cgImageIsBGRXInterpretedAsRGB() throws {
    var fb = Framebuffer(width: 1, height: 1)
    fb.applyRaw(x: 0, y: 0, width: 1, height: 1, data: [0x10, 0x20, 0x30, 0])  // B G R X
    let image = try fb.cgImage()
    let data = image.dataProvider!.data! as Data
    #expect(Array(data) == [0x10, 0x20, 0x30, 0])
    #expect(image.bitmapInfo.contains(.byteOrder32Little))
    #expect(image.alphaInfo == .noneSkipFirst)
    #expect(try fb.pngData().count > 8)
  }

  @Test func emptyFramebufferHasNoImage() {
    #expect(throws: RFBError.emptyFramebuffer) { try Framebuffer(width: 0, height: 0).cgImage() }
  }
}
