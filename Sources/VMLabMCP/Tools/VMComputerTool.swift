import VMLabCore

extension ToolSpec {
  static let vmComputer = ToolSpec(
    name: "vm_computer",
    summary:
      "See and drive the guest's display like a computer-use tool. screenshot returns an image "
      + "scaled so its long edge is at most maxEdge (default 1280) with the scale used; pass "
      + "diffFrom a previous screenshot id to get only the changed region, or unchanged: true. "
      + "zoom crops region at full resolution. Clicks, drags, mouse_move, type, key (xdotool "
      + "names such as Return, ctrl+c, cmd+space), scroll and wait act, then return a fresh "
      + "screenshot after settleMs (at most \(VMComputerHandler.maxSettleMs) ms). Coordinates are "
      + "guest pixels unless scaled: true, which means the coordinates of the last scaled "
      + "screenshot; each coordinate and region corner is 0 to \(DisplayRect.coordinateLimit). "
      + "wait lasts at most \(Int(VMComputerHandler.maxWaitSeconds)) s; scroll sends at most "
      + "\(VMComputerHandler.maxScrollAmount) clicks. cursor_position and screen_info return no "
      + "image. Needs the gui feature.",
    inputSchema: Schema.input(
      [
        "vm": Schema.vm,
        "action": Schema.action(
          [
            "screenshot", "left_click", "right_click", "middle_click", "double_click",
            "triple_click", "left_click_drag", "mouse_move", "cursor_position", "type", "key",
            "scroll", "wait", "zoom", "screen_info",
          ], "What to do."),
        "coordinate": point("[x, y]: the click, move or scroll point; the drag's end."),
        "startCoordinate": point("left_click_drag: [x, y] where the drag starts."),
        "text": Schema.string("type: the text to type; key: the key or chord, e.g. ctrl+alt+t."),
        "scrollDirection": Schema.string(
          "scroll: direction.", enum: ["up", "down", "left", "right"]),
        "scrollAmount": Schema.integer(
          "scroll: wheel clicks.", minimum: 1, maximum: VMComputerHandler.maxScrollAmount,
          default: 3),
        "region": Schema.array(
          coordinate,
          "[x0, y0, x1, y1]: screenshot or zoom only this rectangle.", minItems: 4, maxItems: 4),
        "durationSeconds": Schema.number(
          "wait: how long to wait, in seconds.", minimum: 0,
          maximum: VMComputerHandler.maxWaitSeconds),
        "maxEdge": Schema.integer(
          "Longest edge of the returned image in pixels.", minimum: 1,
          default: ScreenshotRequest.defaultMaxEdge),
        "format": Schema.string("Image encoding.", enum: ["png", "jpeg"], default: "png"),
        "quality": Schema.integer(
          "jpeg quality, 1 (smallest) to 100.", minimum: VMComputerHandler.qualityRange.lowerBound,
          maximum: VMComputerHandler.qualityRange.upperBound,
          default: ScreenshotRequest.defaultQuality),
        "diffFrom": Schema.string(
          "screenshot: id of an earlier screenshot of this VM; return only what changed."),
        "scaled": Schema.boolean(
          "Coordinates are in the last screenshot's scaled space, not guest pixels."),
        "settleMs": Schema.integer(
          "Delay in milliseconds before the screenshot that follows an action.", minimum: 0,
          maximum: VMComputerHandler.maxSettleMs, default: VMComputerHandler.defaultSettleMs),
      ], required: ["vm", "action"]),
    outputShape: """
      image content block +
      { id, width, height, scale, changedRegion?: { x, y, width, height }, unchanged? }
      cursor_position: { x, y }; screen_info: { width, height }
      """,
    errors: [.vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .engineError])

  /// One coordinate: the handler refuses any outside `0...DisplayRect.coordinateLimit`.
  private static let coordinate = Schema.integer(
    "Pixel coordinate.", minimum: 0, maximum: DisplayRect.coordinateLimit)

  private static func point(_ description: String) -> JSONValue {
    Schema.array(coordinate, description, minItems: 2, maxItems: 2)
  }
}
