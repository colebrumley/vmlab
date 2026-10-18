import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// `vmlab install-mcp --client claude-code|claude-desktop`: prints the MCP configuration that runs
/// this `vmlab serve` with `VMLAB_HOME`; `--write` merges it into the client's file instead.
struct InstallMCPCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "install-mcp",
    abstract: "Print (or with --write, install) the MCP configuration for a client.",
    discussion: """
      Without --write nothing is changed: the JSON to put under mcpServers is printed, and for \
      Claude Code also the equivalent `claude mcp add` command. With --write the entry is merged \
      into ~/.claude.json (Claude Code, user scope) or \
      ~/Library/Application Support/Claude/claude_desktop_config.json (Claude Desktop), keeping \
      every other key; restart Claude Desktop afterwards.
      """)

  @Option(help: "claude-code or claude-desktop.") var client: MCPClient
  @Flag(help: "Write the client's configuration file instead of printing.") var write = false
  @Option(help: "The server's name under mcpServers.") var name = "vmlab"
  @Option(help: "The vmlab executable the client runs (default: this one).") var command: String?
  @Option(help: "The VMLAB_HOME the server uses (default: VMLAB_HOME or ~/.vmlab).")
  var vmlabHome: String?

  func entry(environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPServerEntry
  {
    let executable =
      command.map { URL(filePath: $0).standardizedFileURL.path }
      ?? Bundle.main.executableURL?.standardizedFileURL.path ?? "vmlab"
    let home =
      vmlabHome.map { URL(filePath: $0).standardizedFileURL.path }
      ?? Store.defaultHome(environment: environment).path
    return MCPServerEntry(name: name, command: executable, vmlabHome: home)
  }

  /// The printed text: the client's file, the snippet, and for Claude Code the CLI equivalent.
  func printed(_ entry: MCPServerEntry, home: URL) throws -> String {
    var text = "# Add to \(client.configURL(home: home).path):\n" + (try entry.snippet(for: client))
    if client == .claudeCode {
      text +=
        "# or run:\n" + entry.claudeCommand.map(Self.shellQuoted).joined(separator: " ") + "\n"
    }
    text += "# or: vmlab install-mcp --client \(client.rawValue) --write\n"
    return text
  }

  static func shellQuoted(_ word: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
    if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// The user's home: `HOME`, else the account's home directory.
  static func userHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    environment["HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
  }

  func run() throws {
    let home = Self.userHome()
    let entry = entry()
    guard write else {
      print(try printed(entry, home: home), terminator: "")
      return
    }
    do {
      let url = try entry.write(for: client, home: home)
      print("wrote mcpServers.\(entry.name) to \(url.path)")
    } catch {
      throw ValidationError("could not write \(client.configURL(home: home).path): \(error)")
    }
  }
}

extension MCPClient: ExpressibleByArgument {}
