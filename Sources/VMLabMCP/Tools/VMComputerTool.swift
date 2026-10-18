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
      + "screenshot after settleMs. Coordinates are guest pixels unless scaled: true, which "
      + "means the coordinates of the last scaled screenshot. cursor_position and screen_info "
      + "return no image. Needs the gui feature.",
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
        "scrollAmount": Schema.integer("scroll: wheel clicks.", minimum: 1, default: 3),
        "region": Schema.array(
          Schema.integer("Pixel coordinate.", minimum: 0),
          "[x0, y0, x1, y1]: screenshot or zoom only this rectangle.", minItems: 4, maxItems: 4),
        "durationSeconds": Schema.number("wait: how long to wait.", minimum: 0),
        "maxEdge": Schema.integer(
          "Longest edge of the returned image in pixels.", minimum: 1, default: 1280),
        "format": Schema.string("Image encoding.", enum: ["png", "jpeg"], default: "png"),
        "quality": Schema.integer(
          "jpeg quality, 1 (smallest) to 100.", minimum: 1, maximum: 100, default: 80),
        "diffFrom": Schema.string(
          "screenshot: id of an earlier screenshot of this VM; return only what changed."),
        "scaled": Schema.boolean(
          "Coordinates are in the last screenshot's scaled space, not guest pixels."),
        "settleMs": Schema.integer(
          "Delay before the screenshot that follows an action.", minimum: 0, default: 300),
      ], required: ["vm", "action"]),
    outputShape: """
      image content block +
      { id, width, height, scale, changedRegion?: { x, y, width, height }, unchanged? }
      cursor_position: { x, y }; screen_info: { width, height }
      """,
    errors: [.vmNotFound, .wrongState, .capabilityMissing, .invalidRequest, .engineError])

  private static func point(_ description: String) -> JSONValue {
    Schema.array(
      Schema.integer("Pixel coordinate.", minimum: 0), description, minItems: 2, maxItems: 2)
  }
}
