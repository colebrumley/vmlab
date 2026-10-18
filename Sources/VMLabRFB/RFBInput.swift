/// Pointer buttons in an RFB `PointerEvent` mask. Wheel "buttons" are pressed and released to
/// scroll one notch.
public struct PointerButtons: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let left = PointerButtons(rawValue: 1 << 0)
  public static let middle = PointerButtons(rawValue: 1 << 1)
  public static let right = PointerButtons(rawValue: 1 << 2)
  public static let wheelUp = PointerButtons(rawValue: 1 << 3)
  public static let wheelDown = PointerButtons(rawValue: 1 << 4)
  public static let wheelLeft = PointerButtons(rawValue: 1 << 5)
  public static let wheelRight = PointerButtons(rawValue: 1 << 6)
}

/// Client-to-server input messages (RFC 6143 §7.5.4, §7.5.5).
public enum RFBInput {
  /// `KeyEvent`: type 4, down flag, two bytes padding, keysym.
  public static func keyEvent(_ keysym: UInt32, down: Bool) -> [UInt8] {
    [4, down ? 1 : 0, 0, 0] + (0..<4).map { UInt8((keysym >> (24 - 8 * $0)) & 0xff) }
  }

  /// `PointerEvent`: type 5, button mask, x, y. Coordinates are clamped to the 16-bit range.
  public static func pointerEvent(x: Int, y: Int, buttons: PointerButtons) -> [UInt8] {
    let cx = UInt16(clamping: max(0, x))
    let cy = UInt16(clamping: max(0, y))
    return [
      5, buttons.rawValue, UInt8(cx >> 8), UInt8(cx & 0xff), UInt8(cy >> 8), UInt8(cy & 0xff),
    ]
  }

  /// Press each modifier in order, strike the key, release in reverse order.
  public static func chordEvents(_ chord: KeyChord) -> [UInt8] {
    var bytes: [UInt8] = []
    for m in chord.modifiers { bytes += keyEvent(m, down: true) }
    bytes += keyEvent(chord.key, down: true)
    bytes += keyEvent(chord.key, down: false)
    for m in chord.modifiers.reversed() { bytes += keyEvent(m, down: false) }
    return bytes
  }

  /// The press and release that type one character, wrapped in Shift when a US layout needs it.
  /// Nil for a character with no keysym (a control character other than newline or tab).
  public static func characterEvents(_ character: Character) -> [UInt8]? {
    guard let (keysym, shift) = Keysym.forCharacter(character) else { return nil }
    return chordEvents(KeyChord(modifiers: shift ? [Keysym.shiftL] : [], key: keysym))
  }
}

extension RFBClient {
  /// Moves the pointer to (`x`, `y`) in guest framebuffer pixels with `buttons` held.
  public func pointer(x: Int, y: Int, buttons: PointerButtons = []) async throws {
    try await transport.write(RFBInput.pointerEvent(x: x, y: y, buttons: buttons))
  }

  /// Presses (`down`) or releases one key.
  public func key(_ keysym: UInt32, down: Bool) async throws {
    try await transport.write(RFBInput.keyEvent(keysym, down: down))
  }

  /// Strikes a chord: modifiers down in order, key down and up, modifiers up in reverse. With a
  /// `hold`, each event is its own write `hold` apart: macOS Screen Sharing drops key strokes whose
  /// press and release arrive together.
  public func press(_ chord: KeyChord, hold: Duration = .zero) async throws {
    try await send(RFBInput.chordEvents(chord), hold: hold)
  }

  /// Parses and strikes a chord such as `Return`, `cmd+shift+4` or `ctrl+alt+Delete`.
  public func press(_ chord: String, hold: Duration = .zero) async throws {
    try await press(try KeyChord(parsing: chord), hold: hold)
  }

  /// Writes 8-byte key events, all at once or one per `hold`.
  func send(_ events: [UInt8], hold: Duration) async throws {
    guard hold > .zero else { return try await transport.write(events) }
    var offset = 0
    while offset < events.count {
      if offset > 0 { try await Task.sleep(for: hold) }
      try await transport.write(Array(events[offset..<min(offset + 8, events.count)]))
      offset += 8
    }
  }

  /// Types `text` one character at a time, press then release, with Shift where a US layout
  /// needs it and `gap` between characters. Characters with no keysym are skipped.
  public func type(_ text: String, gap: Duration = .milliseconds(10), hold: Duration = .zero)
    async throws
  {
    var first = true
    for character in text {
      guard let events = RFBInput.characterEvents(character) else { continue }
      if !first && gap > .zero { try await Task.sleep(for: gap) }
      first = false
      try await send(events, hold: hold)
    }
  }
}
