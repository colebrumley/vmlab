import CommonCrypto

/// VNC Authentication (RFB security type 2): DES-encrypt the 16-byte challenge with the password.
public enum VNCAuth {
  /// The 8-byte DES key: the password's first 8 bytes, zero padded, each byte bit-reversed.
  static func key(for password: String) -> [UInt8] {
    var key = [UInt8](repeating: 0, count: 8)
    for (i, byte) in password.utf8.prefix(8).enumerated() {
      var reversed: UInt8 = 0
      for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 1 << (7 - bit) }
      key[i] = reversed
    }
    return key
  }

  /// The response to a 16-byte challenge.
  public static func response(challenge: [UInt8], password: String) throws -> [UInt8] {
    guard challenge.count == 16 else {
      throw RFBError.protocolViolation("VNC auth challenge is \(challenge.count) bytes, not 16")
    }
    let key = key(for: password)
    var out = [UInt8](repeating: 0, count: 16)
    var moved = 0
    let status = CCCrypt(
      CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
      key, key.count, nil, challenge, challenge.count, &out, out.count, &moved)
    guard status == kCCSuccess, moved == 16 else {
      throw RFBError.protocolViolation("DES failed with status \(status)")
    }
    return out
  }
}
