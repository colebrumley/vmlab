import Foundation

/// Errors from the GDB remote protocol client. Module-local; the layer that owns a debug session
/// maps these to model-facing error codes.
public enum GDBError: Error, Sendable, Equatable {
  /// The TCP connection to the stub could not be made.
  case connectionFailed(String)
  /// The stub closed the connection.
  case connectionClosed
  /// The stub did not answer within the deadline.
  case timeout(seconds: Double)
  /// The stub rejected a packet with `-` more times than the client retransmits.
  case tooManyRetransmits
  /// The stub answered `E nn` (`message` is set for the `E.text` form).
  case stubError(code: Int, message: String?)
  /// The stub answered with an empty packet: it does not implement `packet`.
  case unsupported(packet: String)
  /// A reply could not be parsed.
  case malformedReply(String)
  /// The command needs a stopped target and the target is running.
  case targetRunning
  /// No register by that name in the register map.
  case unknownRegister(String)
  /// The stub serves no `target.xml` and no fallback architecture was given.
  case noTargetDescription
  /// The target description could not be parsed.
  case badTargetDescription(String)
}
