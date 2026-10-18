/// An RFB PIXEL_FORMAT (16 bytes on the wire).
public struct PixelFormat: Equatable, Sendable {
  public var bitsPerPixel: UInt8
  public var depth: UInt8
  public var bigEndian: Bool
  public var trueColour: Bool
  public var redMax: UInt16
  public var greenMax: UInt16
  public var blueMax: UInt16
  public var redShift: UInt8
  public var greenShift: UInt8
  public var blueShift: UInt8

  /// 32-bit little-endian true colour with blue in byte 0, green 1, red 2, padding 3 (BGRX).
  public static let bgrx = PixelFormat(
    bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true,
    redMax: 255, greenMax: 255, blueMax: 255, redShift: 16, greenShift: 8, blueShift: 0)

  var bytes: [UInt8] {
    var out: [UInt8] = [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColour ? 1 : 0]
    for v in [redMax, greenMax, blueMax] { out += [UInt8(v >> 8), UInt8(v & 0xff)] }
    out += [redShift, greenShift, blueShift, 0, 0, 0]
    return out
  }

  init(
    bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColour: Bool, redMax: UInt16,
    greenMax: UInt16, blueMax: UInt16, redShift: UInt8, greenShift: UInt8, blueShift: UInt8
  ) {
    self.bitsPerPixel = bitsPerPixel
    self.depth = depth
    self.bigEndian = bigEndian
    self.trueColour = trueColour
    self.redMax = redMax
    self.greenMax = greenMax
    self.blueMax = blueMax
    self.redShift = redShift
    self.greenShift = greenShift
    self.blueShift = blueShift
  }

  init(bytes b: [UInt8]) {
    self.init(
      bitsPerPixel: b[0], depth: b[1], bigEndian: b[2] != 0, trueColour: b[3] != 0,
      redMax: UInt16(b[4]) << 8 | UInt16(b[5]), greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
      blueMax: UInt16(b[8]) << 8 | UInt16(b[9]), redShift: b[10], greenShift: b[11],
      blueShift: b[12])
  }
}
