/// X11 keysyms for a US keyboard: printable ASCII and the named keys a model asks for.
public enum Keysym {
  public static let backSpace: UInt32 = 0xff08
  public static let tab: UInt32 = 0xff09
  public static let returnKey: UInt32 = 0xff0d
  public static let escape: UInt32 = 0xff1b
  public static let delete: UInt32 = 0xffff
  public static let shiftL: UInt32 = 0xffe1
  public static let controlL: UInt32 = 0xffe3
  public static let altL: UInt32 = 0xffe9
  public static let superL: UInt32 = 0xffeb

  /// Characters a US layout types with Shift held (besides `A`-`Z`).
  private static let shifted: Set<Character> = Set("~!@#$%^&*()_+{}|:\"<>?")

  /// The keysym that types `character`, and whether Shift must be held for it on a US layout.
  /// Printable ASCII maps to itself, `\n` to Return and `\t` to Tab; other characters use the
  /// Latin-1 or Unicode (`0x0100_0000 + scalar`) keysym without Shift.
  public static func forCharacter(_ character: Character) -> (keysym: UInt32, shift: Bool)? {
    if character == "\n" || character == "\r\n" || character == "\r" { return (returnKey, false) }
    if character == "\t" { return (tab, false) }
    let scalars = character.unicodeScalars
    guard scalars.count == 1, let scalar = scalars.first else { return nil }
    let value = scalar.value
    switch value {
    case 0x20...0x7e:
      let shift = ("A"..."Z").contains(character) || shifted.contains(character)
      return (value, shift)
    case 0xa0...0xff:
      return (value, false)
    case 0x100...0x10ffff:
      return (0x0100_0000 + value, false)
    default:
      return nil
    }
  }

  /// Named keys, matched case-insensitively: the X11 names plus the aliases models use.
  private static let names: [String: UInt32] = {
    var table: [String: UInt32] = [
      "backspace": backSpace, "tab": tab, "return": returnKey, "enter": returnKey,
      "escape": escape, "esc": escape, "delete": delete, "del": delete,
      "insert": 0xff63, "home": 0xff50, "end": 0xff57,
      "page_up": 0xff55, "pageup": 0xff55, "prior": 0xff55,
      "page_down": 0xff56, "pagedown": 0xff56, "next": 0xff56,
      "left": 0xff51, "up": 0xff52, "right": 0xff53, "down": 0xff54,
      "arrowleft": 0xff51, "arrowup": 0xff52, "arrowright": 0xff53, "arrowdown": 0xff54,
      "space": 0x20, "menu": 0xff67, "print": 0xff61, "pause": 0xff13,
      "scroll_lock": 0xff14, "num_lock": 0xff7f, "caps_lock": 0xffe5, "kp_enter": 0xff8d,
      "shift": shiftL, "shift_l": shiftL, "shift_r": 0xffe2,
      "ctrl": controlL, "control": controlL, "control_l": controlL, "control_r": 0xffe4,
      "alt": altL, "alt_l": altL, "alt_r": 0xffea, "option": altL,
      "meta": 0xffe7, "meta_l": 0xffe7, "meta_r": 0xffe8,
      // `cmd` is the macOS guest's Command key, which its VNC server reads as Super_L.
      "cmd": superL, "command": superL, "super": superL, "super_l": superL, "super_r": 0xffec,
      "win": superL,
    ]
    for n in 1...24 { table["f\(n)"] = 0xffbe + UInt32(n - 1) }
    return table
  }()

  /// The keysym for a named key such as `Return`, `F5`, `ctrl` or `cmd`, or nil.
  public static func named(_ name: String) -> UInt32? { names[name.lowercased()] }
}

/// A key combination such as `cmd+shift+4` or `ctrl+alt+Delete`: the keys held, in press order,
/// then the key struck.
public struct KeyChord: Equatable, Sendable {
  public var modifiers: [UInt32]
  public var key: UInt32

  public init(modifiers: [UInt32] = [], key: UInt32) {
    self.modifiers = modifiers
    self.key = key
  }

  /// Parses `+`-separated key names. Each part is a named key (`Keysym.named`) or one character;
  /// a final character that needs Shift on a US layout (`ctrl+A`) adds Shift if it is not held.
  /// `+` itself is written as the last part (`ctrl++`).
  public init(parsing text: String) throws {
    var parts: [Substring]
    if text == "+" {
      parts = ["+"]
    } else if text.hasSuffix("++") {
      parts = text.dropLast(2).split(separator: "+", omittingEmptySubsequences: false) + ["+"]
    } else {
      parts = text.split(separator: "+", omittingEmptySubsequences: false)
    }
    var keysyms: [UInt32] = []
    var lastNeedsShift = false
    for part in parts {
      let name = String(part)
      if let keysym = Keysym.named(name) {
        keysyms.append(keysym)
        lastNeedsShift = false
      } else if name.count == 1, let typed = Keysym.forCharacter(name.first!) {
        keysyms.append(typed.keysym)
        lastNeedsShift = typed.shift
      } else {
        throw RFBError.unknownKey(name.isEmpty ? text : name)
      }
    }
    key = keysyms.removeLast()
    modifiers = keysyms
    if lastNeedsShift && !modifiers.contains(Keysym.shiftL) && !modifiers.contains(0xffe2) {
      modifiers.append(Keysym.shiftL)
    }
  }
}
