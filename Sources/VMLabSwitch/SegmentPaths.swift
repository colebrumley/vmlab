import Foundation

/// The files of one segment: `$VMLAB_HOME/segments/<name>/` (Appendix F).
public struct SegmentPaths: Sendable, Equatable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// The segment `name` under `VMLAB_HOME`, or `~/.vmlab` when it is unset or empty.
  public init(
    name: String, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    guard Self.isValidName(name) else { throw SwitchError.invalidSegmentName(name) }
    let home =
      environment["VMLAB_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vmlab")
    self.directory = home.appending(path: "segments").appending(path: name)
  }

  /// Lowercase letters, digits and `-`, starting with a letter or digit, at most 32 characters.
  public static func isValidName(_ name: String) -> Bool {
    guard let first = name.utf8.first, name.utf8.count <= 32, first != UInt8(ascii: "-") else {
      return false
    }
    return name.utf8.allSatisfy { c in
      (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
        || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-")
    }
  }

  /// Guests' ports send frames here (unix datagram).
  public var switchSocket: URL { directory.appending(path: "switch.sock") }
  /// A connection here receives one JSON `SwitchStats` object (unix stream).
  public var statsSocket: URL { directory.appending(path: "stats.sock") }
  public var pidFile: URL { directory.appending(path: "switch.pid") }
  /// A connection here hands the switch one end of a datagram `socketpair` with `SCM_RIGHTS`
  /// (VZ guests, R-901); the switch answers `ok` once the port is added.
  public var attachSocket: URL { directory.appending(path: "attach.sock") }
  /// Where guests' port sockets are bound (R-901).
  public var portsDirectory: URL { directory.appending(path: "ports") }
}

public enum SwitchError: Error, Equatable, CustomStringConvertible {
  case invalidSegmentName(String)
  case pathTooLong(String)
  case alreadyRunning(pid: Int32)
  case system(call: String, errno: Int32)

  public var description: String {
    switch self {
    case .invalidSegmentName(let name):
      "invalid segment name \"\(name)\": use [a-z0-9-], at most 32 characters"
    case .pathTooLong(let path): "socket path is longer than 103 bytes: \(path)"
    case .alreadyRunning(let pid): "a switch for this segment is already running (pid \(pid))"
    case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
    }
  }
}
