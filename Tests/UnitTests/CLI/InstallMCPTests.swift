import Foundation
import Testing
import VMLabMCP

@testable import vmlab

/// `vmlab install-mcp`: flags, defaults, and the printed text. Nothing here writes a file.
@Suite struct InstallMCPTests {
  @Test func defaultsToPrintingWithVMLABHomeFromTheEnvironment() throws {
    let command = try InstallMCPCommand.parse(["--client", "claude-code"])
    #expect(!command.write)
    let entry = command.entry(environment: ["VMLAB_HOME": "/srv/vmlab"])
    #expect(entry.vmlabHome == "/srv/vmlab")
    #expect(entry.name == "vmlab")
    #expect(entry.command.hasPrefix("/"))
  }

  @Test func flagsOverrideTheEntry() throws {
    let command = try InstallMCPCommand.parse([
      "--client", "claude-desktop", "--name", "lab", "--command", "/opt/bin/vmlab",
      "--vmlab-home", "/data/vmlab", "--write",
    ])
    #expect(command.write)
    #expect(command.client == .claudeDesktop)
    #expect(
      command.entry(environment: [:])
        == MCPServerEntry(name: "lab", command: "/opt/bin/vmlab", vmlabHome: "/data/vmlab"))
  }

  @Test func rejectsAnUnknownClient() {
    #expect(throws: (any Error).self) { try InstallMCPCommand.parse(["--client", "cursor"]) }
  }

  @Test func printedTextNamesTheFileAndTheClaudeCommand() throws {
    let command = try InstallMCPCommand.parse([
      "--client", "claude-code", "--command", "/Apps/My Tools/vmlab", "--vmlab-home", "/h",
    ])
    let text = try command.printed(command.entry(), home: URL(filePath: "/Users/me"))
    #expect(text.contains("/Users/me/.claude.json"))
    #expect(text.contains("\"mcpServers\""))
    #expect(
      text.contains(
        "claude mcp add vmlab --scope user -e VMLAB_HOME=/h -- '/Apps/My Tools/vmlab' serve"))
  }

  @Test func userHomeReadsHOME() {
    #expect(InstallMCPCommand.userHome(environment: ["HOME": "/tmp/x"]).path == "/tmp/x")
  }
}
