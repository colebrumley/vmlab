import Foundation

/// One screenshot result: what the model sees, plus where it sits on the guest screen.
public struct Screenshot: Equatable, Sendable {
  /// The id to pass back as `diffFrom`.
  public var id: String
  /// The guest screen size in pixels (unscaled).
  public var width: Int
  public var height: Int
  /// Image pixels per guest pixel.
  public var scale: Double
  /// The encoded image; `nil` when `unchanged`.
  public var image: EncodedImage?
  /// With `diffFrom`: the guest rectangle that changed, which `image` shows (its origin is the
  /// offset). The whole frame when the screen size changed. `nil` without `diffFrom`.
  public var changedRegion: PixelRect?
  /// With `diffFrom`: nothing in the frame changed, and no image is returned.
  public var unchanged: Bool
}

extension Framebuffer {
  /// The bounding box of pixels inside `frame` that differ from `other` (the X byte is ignored),
  /// or `nil` when none do. Both framebuffers must be the same size and `frame` inside them.
  public func changedRect(from other: Framebuffer, within frame: PixelRect) -> PixelRect? {
    precondition(width == other.width && height == other.height)
    precondition(contains(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
    var top = Int.max
    var bottom = -1
    var left = Int.max
    var right = -1
    pixels.withUnsafeBytes { a in
      other.pixels.withUnsafeBytes { b in
        for row in frame.y..<(frame.y + frame.height) {
          let start = (row * width + frame.x) * 4
          let length = frame.width * 4
          if memcmp(a.baseAddress! + start, b.baseAddress! + start, length) == 0 { continue }
          var first = -1
          var last = -1
          for col in 0..<frame.width {
            let o = start + col * 4
            let pa = a.loadUnaligned(fromByteOffset: o, as: UInt32.self) & 0x00FF_FFFF
            let pb = b.loadUnaligned(fromByteOffset: o, as: UInt32.self) & 0x00FF_FFFF
            if pa != pb {
              if first < 0 { first = col }
              last = col
            }
          }
          guard first >= 0 else { continue }
          top = min(top, row)
          bottom = row
          left = min(left, frame.x + first)
          right = max(right, frame.x + last)
        }
      }
    }
    guard bottom >= 0 else { return nil }
    return PixelRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
  }
}

/// The last screenshots taken of one VM, kept so a later screenshot can return only what changed.
/// A value type: the owner (one per VM) keeps it inside its own actor.
public struct ScreenshotCache: Sendable {
  /// How many screenshots are kept; older ones can no longer be named in `diffFrom`.
  public static let defaultCapacity = 20

  struct Entry: Sendable {
    var id: String
    var width: Int
    var height: Int
    /// The BGRX pixels, LZFSE-compressed (screens compress well; 20 raw 4K frames would be 660 MB).
    var compressed: Data
  }

  public let capacity: Int
  private let prefix: String
  private var counter = 0
  private(set) var entries: [Entry] = []

  public init(capacity: Int = Self.defaultCapacity) {
    precondition(capacity >= 1)
    self.capacity = capacity
    prefix = String(UInt32.random(in: 0...UInt32.max), radix: 16)
  }

  /// The ids that `diffFrom` may name, oldest first.
  public var ids: [String] { entries.map(\.id) }

  /// Records `framebuffer` under a new id and encodes it per `options`. With `diffFrom`, returns only
  /// the bounding box that changed since that screenshot (inside the region, if one is given), or
  /// `unchanged: true` with no image. The diff image uses the scale the whole frame would get.
  public mutating func capture(
    _ framebuffer: Framebuffer, options: ScreenshotOptions = .init(), diffFrom: String? = nil
  ) throws -> Screenshot {
    let frame = try options.frame(width: framebuffer.width, height: framebuffer.height)
    let scale = options.scale(for: frame)
    var base: Framebuffer?
    if let diffFrom {
      guard let entry = entries.first(where: { $0.id == diffFrom }) else {
        throw RFBError.invalidScreenshotRequest(
          field: "diffFrom",
          reason: "no screenshot \(diffFrom); only the last \(capacity) are kept")
      }
      base = try Self.restore(entry)
    }
    var result = Screenshot(
      id: try store(framebuffer), width: framebuffer.width, height: framebuffer.height,
      scale: scale, image: nil, changedRegion: nil, unchanged: false)
    var rect = frame
    if let base {
      if base.width == framebuffer.width && base.height == framebuffer.height {
        guard let changed = framebuffer.changedRect(from: base, within: frame) else {
          result.unchanged = true
          return result
        }
        rect = changed
      }
      result.changedRegion = rect
    }
    result.image = try ScreenshotEncoder.encode(
      framebuffer, rect: rect, scale: scale, options: options)
    return result
  }

  private mutating func store(_ framebuffer: Framebuffer) throws -> String {
    counter += 1
    let id = "\(prefix)-\(counter)"
    let compressed: Data
    do {
      compressed = try (Data(framebuffer.pixels) as NSData).compressed(using: .lzfse) as Data
    } catch {
      throw RFBError.emptyFramebuffer
    }
    entries.append(
      Entry(id: id, width: framebuffer.width, height: framebuffer.height, compressed: compressed))
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    return id
  }

  private static func restore(_ entry: Entry) throws -> Framebuffer {
    let raw: Data
    do {
      raw = try (entry.compressed as NSData).decompressed(using: .lzfse) as Data
    } catch {
      throw RFBError.emptyFramebuffer
    }
    guard raw.count == entry.width * entry.height * 4 else { throw RFBError.emptyFramebuffer }
    return Framebuffer(width: entry.width, height: entry.height, pixels: [UInt8](raw))
  }
}
