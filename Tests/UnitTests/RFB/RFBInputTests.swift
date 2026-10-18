import Testing

@testable import VMLabRFB

private func ev(_ keysym: UInt32, _ down: Bool) -> [UInt8] {
  [
    4, down ? 1 : 0, 0, 0, UInt8(keysym >> 24), UInt8((keysym >> 16) & 0xff),
    UInt8((keysym >> 8) & 0xff), UInt8(keysym & 0xff),
  ]
}

private func connectedClient() async throws -> (RFBClient, ReplayTransport, Int) {
  let transport = ReplayTransport(serverBytes: try rfbFixture("qemu-ramfb-640x480.bin"))
  let client = try await RFBClient.handshake(over: transport)
  return (client, transport, await transport.written.count)
}

@Suite struct RFBInputTests {
  @Test func keyEventBytes() {
    #expect(RFBInput.keyEvent(0xff0d, down: true) == [4, 1, 0, 0, 0, 0, 0xff, 0x0d])
    #expect(RFBInput.keyEvent(0x61, down: false) == [4, 0, 0, 0, 0, 0, 0, 0x61])
  }

  @Test func pointerEventBytesAndClamping() {
    #expect(
      RFBInput.pointerEvent(x: 640, y: 480, buttons: [.left, .right])
        == [5, 5, 0x02, 0x80, 0x01, 0xe0])
    #expect(RFBInput.pointerEvent(x: -3, y: 70000, buttons: []) == [5, 0, 0, 0, 0xff, 0xff])
  }

  @Test func chordCmdShift4() async throws {
    let (client, transport, start) = try await connectedClient()
    try await client.press("cmd+shift+4")
    let expected =
      ev(0xffeb, true) + ev(0xffe1, true) + ev(0x34, true) + ev(0x34, false)
      + ev(0xffe1, false) + ev(0xffeb, false)
    #expect(Array(await transport.written[start...]) == expected)
  }

  /// R-607: with a hold, a chord's events go out one at a time (macOS Screen Sharing drops a
  /// stroke whose press and release arrive together); the bytes are unchanged.
  @Test func heldChordSpacesItsEvents() async throws {
    let (client, transport, start) = try await connectedClient()
    #expect(client.serverVersion.hasPrefix("RFB 003."))
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
      try await client.press("cmd+space", hold: .milliseconds(20))
    }
    #expect(elapsed >= .milliseconds(60))
    #expect(
      Array(await transport.written[start...])
        == ev(0xffeb, true) + ev(0x20, true) + ev(0x20, false) + ev(0xffeb, false))
  }

  /// Codex CX-33: cancelling a held chord between its events skipped the releases, leaving
  /// modifiers held on the guest. Whatever was pressed is released.
  @Test func cancelledHeldChordReleasesWhatItPressed() async throws {
    let (client, transport, start) = try await connectedClient()
    let pressing = Task { try await client.press("cmd+shift+4", hold: .milliseconds(200)) }
    try await Task.sleep(for: .milliseconds(300))
    pressing.cancel()
    await #expect(throws: CancellationError.self) { try await pressing.value }
    let written = Array(await transport.written[start...])
    #expect(
      written == ev(0xffeb, true) + ev(0xffe1, true) + ev(0xffe1, false) + ev(0xffeb, false))
    // A cancelled type releases its Shift too.
    let (typer, typed, from) = try await connectedClient()
    let typing = Task { try await typer.type("A", hold: .milliseconds(200)) }
    try await Task.sleep(for: .milliseconds(100))
    typing.cancel()
    _ = try? await typing.value
    #expect(Array(await typed.written[from...]) == ev(0xffe1, true) + ev(0xffe1, false))
  }

  @Test func chordCtrlAltDelete() throws {
    let chord = try KeyChord(parsing: "ctrl+alt+Delete")
    #expect(chord == KeyChord(modifiers: [0xffe3, 0xffe9], key: 0xffff))
    #expect(
      RFBInput.chordEvents(chord)
        == ev(0xffe3, true) + ev(0xffe9, true) + ev(0xffff, true) + ev(0xffff, false)
        + ev(0xffe9, false) + ev(0xffe3, false))
  }

  @Test func typeHelloWorld() async throws {
    let (client, transport, start) = try await connectedClient()
    try await client.type("Hello, World!", gap: .zero)
    func plain(_ c: UInt8) -> [UInt8] { ev(UInt32(c), true) + ev(UInt32(c), false) }
    func shifted(_ c: UInt8) -> [UInt8] { ev(0xffe1, true) + plain(c) + ev(0xffe1, false) }
    let expected =
      shifted(0x48) + plain(0x65) + plain(0x6c) + plain(0x6c) + plain(0x6f) + plain(0x2c)
      + plain(0x20) + shifted(0x57) + plain(0x6f) + plain(0x72) + plain(0x6c) + plain(0x64)
      + shifted(0x21)
    #expect(Array(await transport.written[start...]) == expected)
  }

  @Test func typeWaitsBetweenCharacters() async throws {
    let (client, _, _) = try await connectedClient()
    let clock = ContinuousClock()
    let elapsed = try await clock.measure { try await client.type("abcd") }
    #expect(elapsed >= .milliseconds(30))
  }

  @Test func namedKeysAndAliases() {
    #expect(Keysym.named("Return") == 0xff0d)
    #expect(Keysym.named("enter") == 0xff0d)
    #expect(Keysym.named("Tab") == 0xff09)
    #expect(Keysym.named("Escape") == 0xff1b)
    #expect(Keysym.named("Up") == 0xff52)
    #expect(Keysym.named("Left") == 0xff51)
    #expect(Keysym.named("F1") == 0xffbe)
    #expect(Keysym.named("F12") == 0xffc9)
    #expect(Keysym.named("cmd") == Keysym.superL)
    #expect(Keysym.named("Super_L") == 0xffeb)
    #expect(Keysym.named("Page_Down") == 0xff56)
    #expect(Keysym.named("nope") == nil)
  }

  @Test func printableASCIITable() {
    for value in UInt32(0x20)...0x7e {
      let c = Character(Unicode.Scalar(value)!)
      #expect(Keysym.forCharacter(c)?.keysym == value)
    }
    #expect(Keysym.forCharacter("a")?.shift == false)
    #expect(Keysym.forCharacter("Z")?.shift == true)
    #expect(Keysym.forCharacter("?")?.shift == true)
    #expect(Keysym.forCharacter("/")?.shift == false)
    #expect(Keysym.forCharacter("\n")! == (0xff0d, false))
    #expect(Keysym.forCharacter("é")! == (0xe9, false))
    #expect(Keysym.forCharacter("€")! == (0x0100_20ac, false))
  }

  @Test func chordEdgeCases() throws {
    #expect(try KeyChord(parsing: "ctrl++") == KeyChord(modifiers: [0xffe3, 0xffe1], key: 0x2b))
    #expect(try KeyChord(parsing: "ctrl+A") == KeyChord(modifiers: [0xffe3, 0xffe1], key: 0x41))
    #expect(try KeyChord(parsing: "shift+A") == KeyChord(modifiers: [0xffe1], key: 0x41))
    #expect(throws: RFBError.unknownKey("bogus")) { try KeyChord(parsing: "ctrl+bogus") }
    #expect(throws: RFBError.unknownKey("ctrl+")) { try KeyChord(parsing: "ctrl+") }
  }
}
