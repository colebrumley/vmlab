/// Errors raised by the RFB client. Module-local: the MCP layer maps them to Appendix D codes.
public enum RFBError: Error, Equatable, Sendable {
  /// The server's version string is not RFB 3.8 or newer.
  case unsupportedVersion(String)
  /// The server refused the connection before security negotiation, with its reason.
  case connectionRefused(String)
  /// The server offers no security type this client implements (None, VNC Authentication).
  case noSupportedSecurityType([UInt8])
  /// The server requires VNC Authentication and no password was given.
  case passwordRequired
  /// The server rejected authentication, with its reason.
  case authenticationFailed(String)
  /// The server sent something this client cannot decode.
  case protocolViolation(String)
  /// The connection closed or the socket failed.
  case connectionClosed
  /// The socket could not be opened.
  case connectFailed(String)
  /// No framebuffer update arrived within the timeout.
  case timeout
  /// The server owed an answer (the handshake, a forced update) and sent nothing for the
  /// dead-peer window (R-1101), with the reason.
  case deadPeer(String)
  /// The framebuffer has no pixels yet.
  case emptyFramebuffer
  /// A key name in a chord is neither a named key nor a single character.
  case unknownKey(String)
  /// A screenshot option is malformed or names an unknown screenshot (maps to `invalid_request`).
  case invalidScreenshotRequest(field: String, reason: String)
}
