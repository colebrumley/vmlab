/// MCP server: tool schemas, handlers, stdio transport.
public enum VMLabMCP {
  /// The package version: `vmlab --version` and the MCP server's `serverInfo.version`. Normal
  /// builds read this literal; `scripts/release.sh` rewrites the line (`version = "…"`) to the
  /// release's version for the release build and restores it afterwards.
  public static let version = "0.1.0"
}
