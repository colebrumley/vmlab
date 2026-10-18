import Foundation

/// The MCP configuration `vmlab install-mcp` prints or writes for a client: `vmlab serve` on
/// stdio, with `VMLAB_HOME` in the environment. Pure: the caller passes the user's home directory,
/// so tests never touch the real client files.
public enum MCPClient: String, Sendable, CaseIterable {
  case claudeCode = "claude-code"
  case claudeDesktop = "claude-desktop"

  /// The file the client reads its MCP servers from: `~/.claude.json` (Claude Code's user scope)
  /// or `~/Library/Application Support/Claude/claude_desktop_config.json`.
  public func configURL(home: URL) -> URL {
    switch self {
    case .claudeCode: home.appending(path: ".claude.json")
    case .claudeDesktop:
      home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
    }
  }
}

/// One server entry under `mcpServers`.
public struct MCPServerEntry: Sendable, Equatable {
  public var name: String
  /// The absolute path of the `vmlab` executable.
  public var command: String
  public var vmlabHome: String

  public init(name: String = "vmlab", command: String, vmlabHome: String) {
    self.name = name
    self.command = command
    self.vmlabHome = vmlabHome
  }

  public var args: [String] { ["serve"] }

  /// The entry's object: `type: stdio` for Claude Code, which records it; Claude Desktop's file
  /// has no `type`.
  public func object(for client: MCPClient) -> [String: Any] {
    var entry: [String: Any] = [
      "command": command, "args": args, "env": ["VMLAB_HOME": vmlabHome],
    ]
    if client == .claudeCode { entry["type"] = "stdio" }
    return entry
  }

  /// `{"mcpServers": {"<name>": {...}}}`, the snippet to paste into the client's file.
  public func snippet(for client: MCPClient) throws -> String {
    try Self.encode(["mcpServers": [name: object(for: client)]])
  }

  /// The `claude mcp add` command that installs the same entry in Claude Code's user scope.
  public var claudeCommand: [String] {
    ["claude", "mcp", "add", "--scope", "user", "-e", "VMLAB_HOME=\(vmlabHome)", name, "--"]
      + [command] + args
  }

  /// `existing` (the client's file, or nil when there is none) with this entry set under
  /// `mcpServers`, every other key and server kept. Refuses a file that is not a JSON object.
  public func merged(into existing: Data?, for client: MCPClient) throws -> Data {
    var root: [String: Any] = [:]
    if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 }) {
      guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
        throw ClientInstallError.notAnObject
      }
      root = object
    }
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    servers[name] = object(for: client)
    root["mcpServers"] = servers
    return Data(try Self.encode(root).utf8)
  }

  /// Writes the merged file atomically, creating its directory; returns the file written.
  @discardableResult
  public func write(for client: MCPClient, home: URL) throws -> URL {
    let url = client.configURL(home: home)
    let existing = FileManager.default.contents(atPath: url.path)
    let data = try merged(into: existing, for: client)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    return url
  }

  static func encode(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self) + "\n"
  }
}

public enum ClientInstallError: Error, CustomStringConvertible {
  case notAnObject

  public var description: String {
    switch self {
    case .notAnObject: "the client's configuration file is not a JSON object; not changing it"
    }
  }
}
