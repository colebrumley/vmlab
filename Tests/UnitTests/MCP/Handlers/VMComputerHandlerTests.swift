import Foundation
import Synchronization
import Testing
import VMLabCore

@testable import VMLabMCP

/// A display that records every input event and returns a fixed-size screen.
final class FakeDisplay: DisplaySession, DisplayConnector {
  enum Event: Equatable {
    case pointer(Int, Int, DisplayButtons)
    case press(String)
    case type(String)
    case screenshot(ScreenshotRequest)
    case close
  }

  let width: Int
  let height: Int
  /// The scale the fake reports, like a 2560-wide screen scaled to 1280.
  let scale: Double
  private let log = Mutex<[Event]>([])
  private let connects = Mutex<[DisplayEndpoint]>([])
  private let counter = Mutex(0)

  init(width: Int = 2560, height: Int = 1600, scale: Double = 0.5) {
    self.width = width
    self.height = height
    self.scale = scale
  }

  var events: [Event] { log.withLock { $0 } }
  var inputs: [Event] {
    events.filter {
      if case .screenshot = $0 { return false }
      return true
    }
  }
  var endpoints: [DisplayEndpoint] { connects.withLock { $0 } }

  func connect(_ endpoint: DisplayEndpoint) async throws(VMLabError) -> any DisplaySession {
    connects.withLock { $0.append(endpoint) }
    return self
  }

  func screenSize() async throws(VMLabError) -> (width: Int, height: Int) { (width, height) }

  func screenshot(_ request: ScreenshotRequest) async throws(VMLabError) -> ScreenCapture {
    log.withLock { $0.append(.screenshot(request)) }
    let n = counter.withLock {
      $0 += 1
      return $0
    }
    if request.diffFrom == "nope" {
      throw VMLabError.invalidRequest(field: "diffFrom", reason: "no screenshot nope", hint: "")
    }
    let unchanged = request.diffFrom != nil
    return ScreenCapture(
      id: "s-\(n)", width: width, height: height, scale: request.maxEdge == nil ? 1 : scale,
      image: unchanged ? nil : Data([0x89, 0x50]), mimeType: unchanged ? nil : "image/png",
      unchanged: unchanged)
  }

  func pointer(x: Int, y: Int, buttons: DisplayButtons) async throws(VMLabError) {
    log.withLock { $0.append(.pointer(x, y, buttons)) }
  }

  func press(_ chord: String) async throws(VMLabError) {
    log.withLock { $0.append(.press(chord)) }
  }

  func type(_ text: String) async throws(VMLabError) {
    log.withLock { $0.append(.type(text)) }
  }

  func close() async { log.withLock { $0.append(.close) } }
}

@Suite struct VMComputerHandlerTests {
  struct Fixture {
    let home: URL
    let display = FakeDisplay()
    let context: ToolContext
    let record: VMRecord

    init(profile: Profile = .qemuHVF, requested: [Feature] = [.gui], state: VMState = .running)
      throws
    {
      home = FileManager.default.temporaryDirectory.appending(
        path: "vmlab-computer-\(UUID().uuidString)")
      context = ToolContext(
        home: home, displays: DisplaySessions(connectors: DisplayConnectorRegistry(display)))
      let guest = GuestSpec(os: .linux, arch: .arm64)
      var draft = VMRecord(
        id: "", name: "desk", profile: profile, guest: guest, features: [.gui, .serial],
        state: state,
        runtime: state.isLive
          ? VMRuntime(pid: 1, controlSocket: "/tmp/c", vncSocket: "/tmp/v.sock", ip: "10.0.0.9")
          : nil)
      draft.plan = Plan(
        profile: profile, guest: guest, resources: ResourceSpec(), features: [.gui, .serial],
        requested: requested, estimatedStartupSeconds: 0)
      record = try context.store.create(draft)
    }

    func call(_ arguments: [String: JSONValue]) async throws(VMLabError) -> ToolResult {
      var arguments = arguments
      arguments["vm"] = .string("desk")
      arguments["settleMs"] = arguments["settleMs"] ?? .number(0)
      return try await ToolHandlers.call(
        "vm_computer", arguments: .object(arguments), context: context)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }
  }

  static func point(_ x: Int, _ y: Int) -> JSONValue {
    .array([.number(Double(x)), .number(Double(y))])
  }

  @Test func screenshotReturnsImageAndGeometry() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let result = try await f.call([
      "action": .string("screenshot"), "format": .string("jpeg"), "quality": .number(50),
    ])
    #expect(result.value["id"] == .string("s-1"))
    #expect(result.value["width"] == .number(2560))
    #expect(result.value["height"] == .number(1600))
    #expect(result.value["scale"] == .number(0.5))
    #expect(result.value["unchanged"] == nil)
    #expect(result.images.count == 1)
    #expect(
      f.display.events == [.screenshot(ScreenshotRequest(format: .jpeg, quality: 50))])
    #expect(
      f.display.endpoints == [
        DisplayEndpoint(address: .unixSocket(path: "/tmp/v.sock"), hostSide: true)
      ])
  }

  @Test func diffFromIsPassedAndUnchangedHasNoImage() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let result = try await f.call(["action": .string("screenshot"), "diffFrom": .string("s-1")])
    #expect(result.value["unchanged"] == .bool(true))
    #expect(result.images.isEmpty)
    let error = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("screenshot"), "diffFrom": .string("nope")])
    }
    #expect(error?.code == .invalidRequest)
  }

  @Test func zoomCropsAtFullResolution() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let result = try await f.call([
      "action": .string("zoom"),
      "region": .array([10.0, 20, 110, 70].map { JSONValue.number($0) }),
    ])
    #expect(result.value["scale"] == .number(1))
    #expect(
      f.display.events == [
        .screenshot(
          ScreenshotRequest(maxEdge: nil, region: DisplayRect(x: 10, y: 20, width: 100, height: 50))
        )
      ])
    let missing = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("zoom")])
    }
    #expect(missing?.data["field"] == .string("region"))
  }

  @Test func clickMovesThenPressesAndReturnsAScreenshot() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let result = try await f.call([
      "action": .string("left_click"), "coordinate": Self.point(100, 200),
    ])
    #expect(
      f.display.inputs == [
        .pointer(100, 200, []), .pointer(100, 200, .left), .pointer(100, 200, []),
      ])
    #expect(result.images.count == 1)
    #expect(result.value["id"] == .string("s-1"))
    // The next click without a coordinate lands where the pointer is.
    _ = try await f.call(["action": .string("right_click")])
    #expect(f.display.inputs.suffix(2) == [.pointer(100, 200, .right), .pointer(100, 200, [])])
    let cursor = try await f.call(["action": .string("cursor_position")])
    #expect(cursor.value["x"] == .number(100) && cursor.value["y"] == .number(200))
    #expect(cursor.images.isEmpty)
  }

  @Test func doubleAndTripleClickRepeatThePress() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.call(["action": .string("triple_click"), "coordinate": Self.point(5, 6)])
    let presses = f.display.inputs.filter { $0 == .pointer(5, 6, .left) }
    #expect(presses.count == 3)
    _ = try await f.call(["action": .string("middle_click")])
    #expect(f.display.inputs.contains(.pointer(5, 6, .middle)))
  }

  @Test func scaledCoordinatesMapThroughTheLastScreenshot() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let early = await #expect(throws: VMLabError.self) {
      try await f.call([
        "action": .string("mouse_move"), "coordinate": Self.point(1, 1), "scaled": .bool(true),
      ])
    }
    #expect(early?.data["field"] == .string("scaled"))
    _ = try await f.call(["action": .string("screenshot")])
    _ = try await f.call([
      "action": .string("mouse_move"), "coordinate": Self.point(640, 400), "scaled": .bool(true),
    ])
    #expect(f.display.inputs == [.pointer(1280, 800, [])])
    #expect(
      Computer.unscale((x: 3, y: 3), frame: .init(originX: 10, originY: 20, scale: 0.5)) == (16, 26)
    )
  }

  @Test func coordinatesOutsideTheScreenAreRefused() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let error = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("left_click"), "coordinate": Self.point(2560, 10)])
    }
    #expect(error?.code == .invalidRequest)
    #expect(error?.data["field"] == .string("coordinate"))
    let unknown = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("left_click")])
    }
    #expect(unknown?.data["field"] == .string("coordinate"))
    #expect(f.display.inputs.isEmpty)
  }

  @Test func dragHoldsTheButtonAlongThePath() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.call([
      "action": .string("left_click_drag"), "startCoordinate": Self.point(0, 0),
      "coordinate": Self.point(80, 160),
    ])
    let inputs = f.display.inputs
    #expect(inputs.first == .pointer(0, 0, []))
    #expect(inputs[1] == .pointer(0, 0, .left))
    #expect(inputs.dropLast().last == .pointer(80, 160, .left))
    #expect(inputs.last == .pointer(80, 160, []))
    #expect(inputs.count == 3 + VMComputerHandler.dragSteps)
    let cursor = try await f.call(["action": .string("cursor_position")])
    #expect(cursor.value["x"] == .number(80))
  }

  @Test func typeKeyAndScroll() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.call(["action": .string("type"), "text": .string("ls -l\n")])
    _ = try await f.call(["action": .string("key"), "text": .string("ctrl+a Delete")])
    _ = try await f.call([
      "action": .string("scroll"), "coordinate": Self.point(10, 10),
      "scrollDirection": .string("down"),
      "scrollAmount": .number(2),
    ])
    #expect(
      f.display.inputs == [
        .type("ls -l\n"), .press("ctrl+a"), .press("Delete"), .pointer(10, 10, []),
        .pointer(10, 10, .wheelDown), .pointer(10, 10, []), .pointer(10, 10, .wheelDown),
        .pointer(10, 10, []),
      ])
    let empty = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("key")])
    }
    #expect(empty?.data["field"] == .string("text"))
    let direction = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("scroll"), "coordinate": Self.point(1, 1)])
    }
    #expect(direction?.data["field"] == .string("scrollDirection"))
  }

  @Test func screenInfoAndWait() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let info = try await f.call(["action": .string("screen_info")])
    #expect(info.value["width"] == .number(2560) && info.value["height"] == .number(1600))
    #expect(info.images.isEmpty)
    let waited = try await f.call(["action": .string("wait"), "durationSeconds": .number(0.01)])
    #expect(waited.images.count == 1)
    let tooLong = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("wait"), "durationSeconds": .number(3600)])
    }
    #expect(tooLong?.data["field"] == .string("durationSeconds"))
  }

  @Test func oneSessionPerVMAcrossCalls() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    _ = try await f.call(["action": .string("screenshot")])
    _ = try await f.call(["action": .string("screen_info")])
    #expect(f.display.endpoints.count == 1)
  }

  @Test func vzWithoutGUIRequestedHasNoDisplay() async throws {
    let f = try Fixture(profile: .vzLinux, requested: [.serial])
    defer { f.cleanUp() }
    let error = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("screenshot")])
    }
    #expect(error?.code == .capabilityMissing)
    #expect(f.display.endpoints.isEmpty)
  }

  @Test func stoppedVMIsWrongState() async throws {
    let f = try Fixture(state: .stopped)
    defer { f.cleanUp() }
    let error = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("screenshot")])
    }
    #expect(error?.code == .wrongState)
  }

  @Test func unknownActionIsInvalid() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    let error = await #expect(throws: VMLabError.self) {
      try await f.call(["action": .string("dance")])
    }
    #expect(error?.code == .invalidRequest)
  }
}
