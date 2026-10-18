import Foundation
import Logging

/// Process-wide logging. Everything goes to stderr: stdout is the MCP transport.
public enum VMLabLogging {
  /// The level named by `VMLAB_LOG` (a swift-log level name, any case); `info` when unset or unknown.
  public static func level(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> Logger.Level
  {
    environment["VMLAB_LOG"].flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info
  }

  /// Installs the stderr handler at the `VMLAB_LOG` level. Call once, first thing in `main`.
  public static func bootstrap(environment: [String: String] = ProcessInfo.processInfo.environment)
  {
    let level = level(environment: environment)
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardError(label: label)
      handler.logLevel = level
      return handler
    }
  }
}
