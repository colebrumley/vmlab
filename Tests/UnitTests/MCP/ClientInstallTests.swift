import Foundation
import Testing
import VMLabMCP

/// The configuration `vmlab install-mcp` prints or writes; every file lives under a temp home.
@Suite struct ClientInstallTests {
  let entry = MCPServerEntry(command: "/opt/vmlab/bin/vmlab", vmlabHome: "/Users/me/.vmlab")

  func object(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  func server(_ root: [String: Any], _ name: String = "vmlab") throws -> [String: Any] {
    let servers = try #require(root["mcpServers"] as? [String: Any])
    return try #require(servers[name] as? [String: Any])
  }

  @Test func claudeCodeSnippetIsAStdioServer() throws {
    let vmlab = try server(object(entry.snippet(for: .claudeCode)))
    #expect(vmlab["type"] as? String == "stdio")
    #expect(vmlab["command"] as? String == "/opt/vmlab/bin/vmlab")
    #expect(vmlab["args"] as? [String] == ["serve"])
    #expect(vmlab["env"] as? [String: String] == ["VMLAB_HOME": "/Users/me/.vmlab"])
  }

  @Test func claudeDesktopSnippetHasNoType() throws {
    let vmlab = try server(object(entry.snippet(for: .claudeDesktop)))
    #expect(vmlab["type"] == nil)
    #expect(vmlab["command"] as? String == "/opt/vmlab/bin/vmlab")
    #expect(vmlab["args"] as? [String] == ["serve"])
    #expect(vmlab["env"] as? [String: String] == ["VMLAB_HOME": "/Users/me/.vmlab"])
  }

  /// The name precedes `-e`, whose values would otherwise swallow it (claude reported "Invalid
  /// environment variable format: vmlab").
  @Test func claudeCommandAddsToUserScope() {
    #expect(
      entry.claudeCommand == [
        "claude", "mcp", "add", "vmlab", "--scope", "user", "-e", "VMLAB_HOME=/Users/me/.vmlab",
        "--", "/opt/vmlab/bin/vmlab", "serve",
      ])
  }

  @Test func configPathsAreUnderTheGivenHome() {
    let home = URL(filePath: "/tmp/h")
    #expect(MCPClient.claudeCode.configURL(home: home).path == "/tmp/h/.claude.json")
    #expect(
      MCPClient.claudeDesktop.configURL(home: home).path
        == "/tmp/h/Library/Application Support/Claude/claude_desktop_config.json")
  }

  @Test func mergeKeepsOtherKeysAndServers() throws {
    let existing = Data(
      #"{"numStartups": 3, "mcpServers": {"other": {"command": "x"}, "vmlab": {"command": "old"}}}"#
        .utf8)
    let root = try object(
      String(decoding: entry.merged(into: existing, for: .claudeCode), as: UTF8.self))
    #expect(root["numStartups"] as? Int == 3)
    #expect(try server(root, "other")["command"] as? String == "x")
    #expect(try server(root)["command"] as? String == "/opt/vmlab/bin/vmlab")
  }

  @Test func mergeRefusesANonObject() {
    #expect(throws: ClientInstallError.self) {
      try entry.merged(into: Data("[1]".utf8), for: .claudeDesktop)
    }
  }

  @Test func writeCreatesTheDesktopFileUnderATempHome() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "vmlab-install-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let url = try entry.write(for: .claudeDesktop, home: home)
    #expect(url.path.hasPrefix(home.path))
    let root = try object(String(decoding: try Data(contentsOf: url), as: UTF8.self))
    #expect(try server(root)["args"] as? [String] == ["serve"])
    // A second write with another server keeps the first.
    try MCPServerEntry(name: "vmlab2", command: "/b", vmlabHome: "/h").write(
      for: .claudeDesktop, home: home)
    let again = try object(String(decoding: try Data(contentsOf: url), as: UTF8.self))
    #expect(try server(again)["command"] as? String == "/opt/vmlab/bin/vmlab")
    #expect(try server(again, "vmlab2")["command"] as? String == "/b")
  }
}
