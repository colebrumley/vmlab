import Foundation
import VMLabCore

/// The display sessions this server holds, one per VM, with what `vm_computer` remembers between
/// calls: the pointer position it last sent and the geometry of the last screenshot (for
/// `scaled: true`). A session's screenshot cache lives inside it, so `diffFrom` works across calls.
public actor DisplaySessions {
  /// How a screenshot's pixels map back to the guest: guest = origin + image / scale.
  public struct Frame: Sendable, Hashable {
    public var originX: Int
    public var originY: Int
    public var scale: Double
  }

  struct Entry {
    var endpoint: DisplayEndpoint
    var session: any DisplaySession
    var cursor: (x: Int, y: Int)?
    var frame: Frame?
  }

  public let connectors: DisplayConnectorRegistry
  private var entries: [String: Entry] = [:]

  public init(connectors: DisplayConnectorRegistry = Displays.shared) {
    self.connectors = connectors
  }

  /// The session of `vm` on `endpoint`, connecting when there is none or the endpoint changed (the
  /// VM restarted elsewhere); the old session is closed.
  public func session(vm: String, endpoint: DisplayEndpoint) async throws(VMLabError)
    -> any DisplaySession
  {
    if let entry = entries[vm], entry.endpoint == endpoint { return entry.session }
    let connector = try connectors.connector()
    let fresh = try await connector.connect(endpoint)
    // Another call may have connected while this one waited.
    if let entry = entries[vm], entry.endpoint == endpoint {
      await fresh.close()
      return entry.session
    }
    if let old = entries[vm] { await old.session.close() }
    entries[vm] = Entry(endpoint: endpoint, session: fresh)
    return fresh
  }

  public func cursor(vm: String) -> (x: Int, y: Int)? { entries[vm]?.cursor }
  public func setCursor(vm: String, x: Int, y: Int) { entries[vm]?.cursor = (x, y) }
  public func frame(vm: String) -> Frame? { entries[vm]?.frame }
  public func setFrame(vm: String, _ frame: Frame) { entries[vm]?.frame = frame }

  /// Closes and drops `vm`'s session.
  public func forget(vm: String) async {
    if let entry = entries.removeValue(forKey: vm) { await entry.session.close() }
  }
}

/// `vm_computer` (R-502): the computer-use action set on the guest display, over the VM's display
/// endpoint (R-503). Coordinates are guest pixels unless `scaled: true`; every acting action
/// returns a fresh screenshot after `settleMs`.
struct VMComputerHandler: ToolHandler {
  static let actions = [
    "screenshot", "left_click", "right_click", "middle_click", "double_click", "triple_click",
    "left_click_drag", "mouse_move", "cursor_position", "type", "key", "scroll", "wait", "zoom",
    "screen_info",
  ]
  /// The longest `wait`.
  static let maxWaitSeconds = 60.0
  /// The pause between the clicks of a double or triple click, and between drag steps.
  static let clickGap = Duration.milliseconds(60)
  /// How long a click holds the button: macOS Screen Sharing ignores a press and release that
  /// arrive together.
  static let buttonHold = Duration.milliseconds(30)
  static let dragSteps = 8

  var spec: ToolSpec { .vmComputer }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let action = try arguments.string("action") ?? ""
    guard Self.actions.contains(action) else {
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(action) is not a vm_computer action",
        hint: "Use one of: \(Self.actions.joined(separator: ", ")).")
    }
    let record = await context.manager.refreshingAddress(
      try context.store.find(try arguments.string("vm") ?? ""))
    let endpoint = try DisplayEndpoint.resolve(
      record, vmDirectory: context.store.directory(of: record.id))
    let session = try await context.displays.session(vm: record.id, endpoint: endpoint)
    let computer = Computer(
      vm: record.id, profile: record.profile, session: session, sessions: context.displays,
      arguments: arguments)
    return try await computer.perform(action)
  }
}

/// One `vm_computer` call.
struct Computer {
  let vm: String
  var profile: Profile = .qemuHVF
  let session: any DisplaySession
  let sessions: DisplaySessions
  let arguments: ToolArguments

  /// The note a `key` result carries on a macOS guest when a chord used Command (R-607).
  static let commandNote =
    "cmd was sent as Super_L, which macOS Screen Sharing reads as the Command key"

  /// The modifier names that send Super_L (`KeyChord`).
  static let commandNames: Set<String> = ["cmd", "command", "super", "super_l", "win"]

  /// Whether any chord of `text` holds Command.
  static func usesCommand(_ text: String) -> Bool {
    text.split(whereSeparator: \.isWhitespace).contains { chord in
      chord.split(separator: "+").contains { commandNames.contains($0.lowercased()) }
    }
  }

  func perform(_ action: String) async throws(VMLabError) -> ToolResult {
    var result = try await act(action)
    if action == "key", profile == .vzMacOS, Self.usesCommand(try requiredText()),
      case .object(var object) = result.value
    {
      object["warnings"] = .array((result.warnings + [Self.commandNote]).map { .string($0) })
      result.value = .object(object)
    }
    return result
  }

  private func act(_ action: String) async throws(VMLabError) -> ToolResult {
    switch action {
    case "screenshot":
      let request = try screenshotRequest(
        region: try await region(), diffFrom: try arguments.string("diffFrom"))
      return try await shoot(request, remember: true)
    case "zoom":
      guard let region = try await region() else {
        throw VMLabError.invalidRequest(
          field: "region", reason: "zoom needs region", hint: "Pass region: [x0, y0, x1, y1].")
      }
      var request = try screenshotRequest(region: region, diffFrom: nil)
      request.maxEdge = nil
      return try await shoot(request, remember: false)
    case "screen_info":
      let size = try await session.screenSize()
      return ToolResult([
        "width": .number(Double(size.width)), "height": .number(Double(size.height)),
      ])
    case "cursor_position":
      guard let cursor = await sessions.cursor(vm: vm) else {
        return ToolResult(
          ["x": .null, "y": .null],
          warnings: ["vmlab has not moved the pointer on this display yet; its position is unknown"]
        )
      }
      return ToolResult(["x": .number(Double(cursor.x)), "y": .number(Double(cursor.y))])
    case "mouse_move":
      let point = try await requiredPoint("coordinate")
      try await move(to: point, buttons: [])
    case "left_click", "right_click", "middle_click", "double_click", "triple_click":
      let point = try await optionalPoint("coordinate")
      let button: DisplayButtons =
        action == "right_click" ? .right : action == "middle_click" ? .middle : .left
      let count = action == "double_click" ? 2 : action == "triple_click" ? 3 : 1
      try await click(at: point, button: button, count: count)
    case "left_click_drag":
      let start = try await requiredPoint("startCoordinate")
      let end = try await requiredPoint("coordinate")
      try await drag(from: start, to: end)
    case "type":
      let text = try requiredText()
      try await session.type(text)
    case "key":
      let text = try requiredText()
      let chords = text.split(whereSeparator: \.isWhitespace).map(String.init)
      guard !chords.isEmpty else { throw Self.emptyText }
      for chord in chords { try await session.press(chord) }
    case "scroll":
      try await scroll()
    case "wait":
      let seconds = try number("durationSeconds") ?? 1
      guard seconds >= 0, seconds <= VMComputerHandler.maxWaitSeconds else {
        throw VMLabError.invalidRequest(
          field: "durationSeconds",
          reason: "durationSeconds must be 0 to \(Int(VMComputerHandler.maxWaitSeconds))",
          hint: "Wait in steps of at most a minute.")
      }
      await pause(.milliseconds(Int(seconds * 1000)))
    default:
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(action) is not a vm_computer action",
        hint: "Use one of: \(VMComputerHandler.actions.joined(separator: ", ")).")
    }
    // Every acting action answers with a fresh screenshot once the guest has had time to react.
    let settle = try arguments.int("settleMs") ?? 300
    guard settle >= 0 else {
      throw VMLabError.invalidRequest(
        field: "settleMs", reason: "settleMs must be at least 0", hint: "Pass 0 or more.")
    }
    if action != "wait" { await pause(.milliseconds(settle)) }
    return try await shoot(try screenshotRequest(region: nil, diffFrom: nil), remember: true)
  }

  // MARK: Input

  private func move(to point: (x: Int, y: Int), buttons: DisplayButtons) async throws(VMLabError) {
    try await session.pointer(x: point.x, y: point.y, buttons: buttons)
    await sessions.setCursor(vm: vm, x: point.x, y: point.y)
  }

  private func click(at point: (x: Int, y: Int)?, button: DisplayButtons, count: Int)
    async throws(VMLabError)
  {
    var target = point
    if target == nil { target = await sessions.cursor(vm: vm) }
    guard let target else {
      throw VMLabError.invalidRequest(
        field: "coordinate", reason: "the pointer position is unknown",
        hint: "Pass coordinate: [x, y] for the first click.")
    }
    try await move(to: target, buttons: [])
    for n in 0..<count {
      if n > 0 { await pause(VMComputerHandler.clickGap) }
      try await session.pointer(x: target.x, y: target.y, buttons: button)
      await pause(VMComputerHandler.buttonHold)
      try await session.pointer(x: target.x, y: target.y, buttons: [])
    }
  }

  private func drag(from start: (x: Int, y: Int), to end: (x: Int, y: Int))
    async throws(VMLabError)
  {
    try await move(to: start, buttons: [])
    try await session.pointer(x: start.x, y: start.y, buttons: .left)
    let steps = VMComputerHandler.dragSteps
    for step in 1...steps {
      await pause(.milliseconds(15))
      let x = start.x + (end.x - start.x) * step / steps
      let y = start.y + (end.y - start.y) * step / steps
      try await session.pointer(x: x, y: y, buttons: .left)
    }
    try await session.pointer(x: end.x, y: end.y, buttons: [])
    await sessions.setCursor(vm: vm, x: end.x, y: end.y)
  }

  private func scroll() async throws(VMLabError) {
    guard let direction = try arguments.string("scrollDirection") else {
      throw VMLabError.invalidRequest(
        field: "scrollDirection", reason: "scroll needs scrollDirection",
        hint: "Pass scrollDirection: up, down, left or right.")
    }
    let wheel: DisplayButtons
    switch direction {
    case "up": wheel = .wheelUp
    case "down": wheel = .wheelDown
    case "left": wheel = .wheelLeft
    case "right": wheel = .wheelRight
    default:
      throw VMLabError.invalidRequest(
        field: "scrollDirection", reason: "\(direction) is not a direction",
        hint: "Use up, down, left or right.")
    }
    let amount = try arguments.int("scrollAmount") ?? 3
    guard (1...100).contains(amount) else {
      throw VMLabError.invalidRequest(
        field: "scrollAmount", reason: "scrollAmount must be 1 to 100", hint: "Scroll less at once."
      )
    }
    var point = try await optionalPoint("coordinate")
    if point == nil { point = await sessions.cursor(vm: vm) }
    guard let point else {
      throw VMLabError.invalidRequest(
        field: "coordinate", reason: "the pointer position is unknown",
        hint: "Pass coordinate: [x, y] where to scroll.")
    }
    try await move(to: point, buttons: [])
    for _ in 0..<amount {
      try await session.pointer(x: point.x, y: point.y, buttons: wheel)
      try await session.pointer(x: point.x, y: point.y, buttons: [])
    }
  }

  // MARK: Screenshots

  private func shoot(_ request: ScreenshotRequest, remember: Bool) async throws(VMLabError)
    -> ToolResult
  {
    let capture = try await session.screenshot(request)
    if remember {
      let region = request.region
      await sessions.setFrame(
        vm: vm,
        .init(
          originX: max(0, region?.x ?? 0), originY: max(0, region?.y ?? 0), scale: capture.scale))
    }
    var object: [String: JSONValue] = [
      "id": .string(capture.id), "width": .number(Double(capture.width)),
      "height": .number(Double(capture.height)), "scale": .number(capture.scale),
    ]
    if let changed = capture.changedRegion { object["changedRegion"] = changed.json }
    if request.diffFrom != nil { object["unchanged"] = .bool(capture.unchanged) }
    var images: [ToolImage] = []
    if let data = capture.image {
      images.append(ToolImage(data: data, mimeType: capture.mimeType ?? "image/png"))
    }
    return ToolResult(object, images: images)
  }

  private func screenshotRequest(region: DisplayRect?, diffFrom: String?) throws(VMLabError)
    -> ScreenshotRequest
  {
    let formatName = try arguments.string("format") ?? "png"
    guard let format = DisplayImageFormat(rawValue: formatName) else {
      throw VMLabError.invalidRequest(
        field: "format", reason: "format must be png or jpeg", hint: "Use png or jpeg.")
    }
    return ScreenshotRequest(
      format: format, quality: try arguments.int("quality") ?? ScreenshotRequest.defaultQuality,
      maxEdge: try arguments.int("maxEdge") ?? ScreenshotRequest.defaultMaxEdge, region: region,
      diffFrom: diffFrom)
  }

  // MARK: Arguments

  /// `region` as a guest rectangle; with `scaled: true` its corners are in the last screenshot's
  /// pixels, like coordinates.
  private func region() async throws(VMLabError) -> DisplayRect? {
    guard let value = arguments["region"] else { return nil }
    let n = try integers(value, field: "region", count: 4)
    var corners = [(x: n[0], y: n[1]), (x: n[2], y: n[3])]
    if try arguments.bool("scaled") {
      let frame = try await lastFrame()
      corners = corners.map { Self.unscale($0, frame: frame) }
    }
    return DisplayRect(corners: corners[0].x, corners[0].y, corners[1].x, corners[1].y)
  }

  private func lastFrame() async throws(VMLabError) -> DisplaySessions.Frame {
    guard let frame = await sessions.frame(vm: vm) else {
      throw VMLabError.invalidRequest(
        field: "scaled", reason: "no screenshot of this VM has been taken yet",
        hint: "Take a screenshot first, or pass guest pixel coordinates without scaled.")
    }
    return frame
  }

  private func requiredPoint(_ field: String) async throws(VMLabError) -> (x: Int, y: Int) {
    guard let point = try await optionalPoint(field) else {
      throw VMLabError.invalidRequest(
        field: field, reason: "\(field) is required for this action", hint: "Pass \(field): [x, y]."
      )
    }
    return point
  }

  /// The point in `field`, in guest pixels, checked against the screen.
  private func optionalPoint(_ field: String) async throws(VMLabError) -> (x: Int, y: Int)? {
    guard let value = arguments[field] else { return nil }
    let numbers = try integers(value, field: field, count: 2)
    var point = (x: numbers[0], y: numbers[1])
    if try arguments.bool("scaled") { point = Self.unscale(point, frame: try await lastFrame()) }
    let size = try await session.screenSize()
    guard (0..<size.width).contains(point.x), (0..<size.height).contains(point.y) else {
      throw VMLabError.invalidRequest(
        field: field,
        reason: "[\(point.x), \(point.y)] is outside the \(size.width)x\(size.height) screen",
        hint: "Coordinates are guest pixels from [0, 0]; pass scaled: true for screenshot pixels.")
    }
    return point
  }

  /// A point in a scaled screenshot's pixels, in guest pixels. Each coordinate is clamped to
  /// `0...DisplayRect.coordinateLimit` (the screen check then refuses it), so no input traps.
  static func unscale(_ point: (x: Int, y: Int), frame: DisplaySessions.Frame) -> (x: Int, y: Int) {
    func guest(_ value: Int, _ origin: Int) -> Int {
      let limit = Double(DisplayRect.coordinateLimit)
      let unscaled = Double(origin) + (Double(value) / frame.scale).rounded(.down)
      guard unscaled.isFinite else { return DisplayRect.coordinateLimit }
      return Int(min(max(unscaled, 0), limit))
    }
    return (guest(point.x, frame.originX), guest(point.y, frame.originY))
  }

  private func integers(_ value: JSONValue, field: String, count: Int) throws(VMLabError) -> [Int] {
    let items = value.arrayValue ?? []
    let numbers = items.compactMap { $0.numberValue.flatMap { Int(exactly: $0) } }
    let limit = DisplayRect.coordinateLimit
    guard items.count == count, numbers.count == count,
      numbers.allSatisfy({ (0...limit).contains($0) })
    else {
      throw VMLabError.invalidRequest(
        field: field, reason: "\(field) must be \(count) integers from 0 to \(limit)",
        hint: count == 2 ? "Pass \(field): [x, y]." : "Pass \(field): [x0, y0, x1, y1].")
    }
    return numbers
  }

  private func number(_ field: String) throws(VMLabError) -> Double? {
    guard let value = arguments[field] else { return nil }
    guard let number = value.numberValue else {
      throw ToolArguments.mismatch(field, "a number")
    }
    return number
  }

  private func requiredText() throws(VMLabError) -> String {
    guard let text = try arguments.string("text"), !text.isEmpty else { throw Self.emptyText }
    return text
  }

  static let emptyText = VMLabError.invalidRequest(
    field: "text", reason: "text is required for this action",
    hint: "Pass text: the characters to type, or the key such as Return or ctrl+c.")

  private func pause(_ duration: Duration) async {
    guard duration > .zero else { return }
    try? await Task.sleep(for: duration)
  }
}
