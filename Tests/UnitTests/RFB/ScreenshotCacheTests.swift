import Foundation
import Testing

@testable import VMLabRFB

@Suite struct ScreenshotCacheTests {
  @Test func changedRectIsTheBoundingBoxOfDifferingPixels() {
    let a = solidScreen(50, 40)
    var b = a
    b.paint(PixelRect(x: 3, y: 5, width: 2, height: 2), (1, 2, 3))
    b.paint(PixelRect(x: 30, y: 20, width: 1, height: 10), (9, 9, 9))
    let all = PixelRect(x: 0, y: 0, width: 50, height: 40)
    #expect(b.changedRect(from: a, within: all) == PixelRect(x: 3, y: 5, width: 28, height: 25))
    #expect(a.changedRect(from: a, within: all) == nil)
    // Restricting the frame ignores changes outside it.
    #expect(
      b.changedRect(from: a, within: PixelRect(x: 10, y: 0, width: 40, height: 40))
        == PixelRect(x: 30, y: 20, width: 1, height: 10))
  }

  @Test func paddingByteDifferencesAreIgnored() {
    let a = solidScreen(4, 4)
    var b = a
    b.applyRaw(x: 2, y: 2, width: 1, height: 1, data: [0, 0, 0, 0xFF])
    #expect(b.changedRect(from: a, within: PixelRect(x: 0, y: 0, width: 4, height: 4)) == nil)
  }

  @Test func singlePixelChangeAtTheCorner() {
    let a = solidScreen(7, 5)
    var b = a
    b.paint(PixelRect(x: 6, y: 4, width: 1, height: 1), (0, 0, 1))
    #expect(
      b.changedRect(from: a, within: PixelRect(x: 0, y: 0, width: 7, height: 5))
        == PixelRect(x: 6, y: 4, width: 1, height: 1))
  }

  @Test func everyResultHasAnIdSizeAndScale() throws {
    var cache = ScreenshotCache()
    let one = try cache.capture(solidScreen(2560, 1600), options: .init(maxEdge: 1280))
    let two = try cache.capture(solidScreen(2560, 1600), options: .init(maxEdge: 1280))
    #expect(one.id != two.id)
    #expect(one.width == 2560 && one.height == 1600 && one.scale == 0.5)
    #expect(one.image?.width == 1280 && one.changedRegion == nil && !one.unchanged)
  }

  @Test func diffFromAnIdenticalScreenIsUnchanged() throws {
    var cache = ScreenshotCache()
    let fb = solidScreen(64, 48, (10, 20, 30))
    let first = try cache.capture(fb)
    let diff = try cache.capture(fb, diffFrom: first.id)
    #expect(diff.unchanged && diff.image == nil && diff.changedRegion == nil)
    #expect(diff.id != first.id && diff.width == 64 && diff.height == 48)
    #expect(cache.ids == [first.id, diff.id])
  }

  @Test func diffFromReturnsOnlyTheChangedBoxAndItsOffset() throws {
    var cache = ScreenshotCache()
    var fb = solidScreen(200, 100)
    let first = try cache.capture(fb, options: .init(maxEdge: nil))
    fb.paint(PixelRect(x: 120, y: 30, width: 40, height: 20), (0, 255, 0))
    let diff = try cache.capture(fb, options: .init(maxEdge: nil), diffFrom: first.id)
    #expect(!diff.unchanged)
    #expect(diff.changedRegion == PixelRect(x: 120, y: 30, width: 40, height: 20))
    let image = try #require(diff.image)
    #expect(image.source == diff.changedRegion && image.scale == 1)
    let d = try decode(image.data)
    #expect(d.width == 40 && d.height == 20 && d.topLeft == [0, 255, 0, 255])
  }

  @Test func diffCropUsesTheFullFrameScale() throws {
    var cache = ScreenshotCache()
    var fb = solidScreen(2000, 1000)
    let first = try cache.capture(fb, options: .init(maxEdge: 1000))
    fb.paint(PixelRect(x: 100, y: 100, width: 200, height: 100), (5, 5, 5))
    let diff = try cache.capture(fb, options: .init(maxEdge: 1000), diffFrom: first.id)
    #expect(diff.scale == 0.5 && diff.image?.width == 100 && diff.image?.height == 50)
  }

  @Test func diffCanDiffAgainstAnOlderScreenshot() throws {
    var cache = ScreenshotCache()
    var fb = solidScreen(30, 30)
    let first = try cache.capture(fb)
    fb.paint(PixelRect(x: 1, y: 1, width: 1, height: 1), (1, 1, 1))
    _ = try cache.capture(fb)
    fb.paint(PixelRect(x: 20, y: 20, width: 1, height: 1), (1, 1, 1))
    let diff = try cache.capture(fb, diffFrom: first.id)
    #expect(diff.changedRegion == PixelRect(x: 1, y: 1, width: 20, height: 20))
  }

  @Test func diffInsideARegionIgnoresChangesOutsideIt() throws {
    var cache = ScreenshotCache()
    var fb = solidScreen(100, 100)
    let region = PixelRect(x: 0, y: 0, width: 50, height: 50)
    let first = try cache.capture(fb, options: .init(region: region))
    fb.paint(PixelRect(x: 80, y: 80, width: 5, height: 5), (1, 1, 1))
    #expect(try cache.capture(fb, options: .init(region: region), diffFrom: first.id).unchanged)
  }

  @Test func resolutionChangeReturnsTheWholeFrame() throws {
    var cache = ScreenshotCache()
    let first = try cache.capture(solidScreen(40, 30))
    let diff = try cache.capture(solidScreen(80, 60), diffFrom: first.id)
    #expect(!diff.unchanged && diff.changedRegion == PixelRect(x: 0, y: 0, width: 80, height: 60))
    #expect(diff.image?.width == 80)
  }

  @Test func onlyTheLastTwentyAreKept() throws {
    var cache = ScreenshotCache()
    let fb = solidScreen(8, 8)
    let first = try cache.capture(fb)
    for _ in 0..<20 { _ = try cache.capture(fb) }
    #expect(cache.ids.count == 20 && !cache.ids.contains(first.id))
    #expect(throws: RFBError.self) { try cache.capture(fb, diffFrom: first.id) }
    #expect(cache.ids.count == 20)  // a refused request stores nothing
  }

  @Test func unknownDiffFromIsAnInvalidRequest() {
    var cache = ScreenshotCache()
    #expect {
      try cache.capture(solidScreen(4, 4), diffFrom: "nope")
    } throws: { error in
      guard case .invalidScreenshotRequest(let field, _) = error as? RFBError else { return false }
      return field == "diffFrom"
    }
  }
}
