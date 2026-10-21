import Foundation

/// A bare arm64 kernel the tests write themselves (R-1200): a Linux arm64 `Image` header and a few
/// hand-encoded instructions that write a message to the PL011 data register of QEMU's `virt`
/// machine (`0x09000000`), then power off through PSCI or wait forever. It boots in well under a
/// second with no cross toolchain, pulled image or checked-in binary.
enum BareKernel {
  /// What the kernel does once the message is out.
  enum Then: Sendable {
    /// PSCI `SYSTEM_OFF` (`x0 = 0x84000008`, `hvc #0`): QEMU sees the guest power off.
    case powerOff
    /// `wfi` in a loop: the guest stays running, idle, until killed.
    case halt
  }

  /// The image's bytes. `message` gets a trailing `\n` unless it has one, so a serial wait for it
  /// matches a whole line; it must not contain a NUL, which ends the print loop.
  static func image(message: String, then: Then) -> Data {
    var text = Array(message.utf8)
    precondition(!text.contains(0), "BareKernel message contains a NUL")
    if text.last != UInt8(ascii: "\n") { text.append(UInt8(ascii: "\n")) }
    text.append(0)

    // Word indices from the first instruction, which sits right after the 64-byte header.
    var code: [UInt32] = [
      0,  // 0: adr x1, message (patched below)
      0xD2A1_2002,  // 1: movz x2, #0x0900, lsl #16      x2 = 0x09000000, the PL011 data register
      0x3840_1423,  // 2: loop: ldrb w3, [x1], #1
      0,  // 3: cbz w3, done (patched below)
      0x3900_0043,  // 4: strb w3, [x2]
      branch(from: 5, to: 2),  // 5: b loop
    ]
    let done = code.count
    code[3] = 0x3400_0000 | (UInt32(done - 3) & 0x7FFFF) << 5 | 3
    if then == .powerOff {
      code += [
        0xD280_0100,  // movz x0, #0x0008
        0xF2B0_8000,  // movk x0, #0x8400, lsl #16      x0 = PSCI SYSTEM_OFF
        0xD400_0002,  // hvc #0
      ]
    }
    // Idle forever: after the message (halt), or should SYSTEM_OFF return (powerOff).
    let idle = code.count
    code += [0xD503_207F, branch(from: idle + 1, to: idle)]  // wfi; b idle
    let offset = UInt32(code.count * 4)  // from the adr to the message
    code[0] = 0x1000_0000 | (offset & 3) << 29 | (offset >> 2 & 0x7FFFF) << 5 | 1

    let size = UInt64(64 + code.count * 4 + text.count)
    var bytes = Data()
    bytes.append(word: branch(from: 0, to: 16))  // code0: b over the 64-byte header
    bytes.append(word: 0)  // code1
    bytes.append(doubleWord: 0x80000)  // text_offset
    bytes.append(doubleWord: size)  // image_size
    bytes.append(doubleWord: 0)  // flags: little-endian, page size unspecified, 2 MB aligned base
    for _ in 0..<3 { bytes.append(doubleWord: 0) }  // res2, res3, res4
    bytes.append(contentsOf: Array("ARM\u{64}".utf8))  // magic, byte 56
    bytes.append(word: 0)  // res5
    for instruction in code { bytes.append(word: instruction) }
    bytes.append(contentsOf: text)
    return bytes
  }

  /// Writes `image(message:then:)` to `url`, replacing any file there.
  static func write(to url: URL, message: String, then: Then) throws {
    try image(message: message, then: then).write(to: url)
  }

  /// `b` from word `from` to word `to`.
  private static func branch(from: Int, to: Int) -> UInt32 {
    0x1400_0000 | UInt32(bitPattern: Int32(to - from)) & 0x3FF_FFFF
  }
}

extension Data {
  fileprivate mutating func append(word: UInt32) {
    Swift.withUnsafeBytes(of: word.littleEndian) { append(contentsOf: $0) }
  }

  fileprivate mutating func append(doubleWord: UInt64) {
    Swift.withUnsafeBytes(of: doubleWord.littleEndian) { append(contentsOf: $0) }
  }
}
