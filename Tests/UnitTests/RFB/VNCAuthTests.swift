import Testing

@testable import VMLabRFB

@Suite struct VNCAuthTests {
  @Test func keyIsBitReversedAndPadded() {
    #expect(VNCAuth.key(for: "secret") == hex("cea6c64ea62e0000"))
    #expect(VNCAuth.key(for: "longer than eight").count == 8)
  }

  /// Cross-checked with `openssl enc -des-ecb -K cea6c64ea62e0000 -nopad`.
  @Test func responseMatchesOpenSSL() throws {
    let response = try VNCAuth.response(
      challenge: Array("0123456789abcdef".utf8), password: "secret")
    #expect(response == hex("752440ee2bfcc2a0d9013fd20371e23b"))
  }

  @Test func shortChallengeIsRejected() {
    #expect(throws: RFBError.self) { try VNCAuth.response(challenge: [1, 2], password: "x") }
  }
}
