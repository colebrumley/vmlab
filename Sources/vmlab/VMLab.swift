import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// The vmlab CLI. Phase 2 (R-2xx) adds the subcommands; `vmlab serve` runs the MCP server.
@main
struct VMLab: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vmlab",
    abstract: "Virtual machines for a language model, over MCP.",
    subcommands: [GenDocs.self]
  )

  static func main() {
    VMLabLogging.bootstrap()
    do {
      var command = try parseAsRoot()
      try command.run()
    } catch {
      exit(withError: error)
    }
  }
}

/// Prints a generated document; `scripts/gen-docs.sh` writes them under `docs/`.
struct GenDocs: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gen-docs",
    abstract: "Print a generated reference document.",
    shouldDisplay: false
  )

  enum Document: String, ExpressibleByArgument, CaseIterable {
    case features, tools
  }

  @Argument(help: "features (docs/FEATURES.md) or tools (docs/TOOLS.md)")
  var document: Document

  func run() {
    switch document {
    case .features: print(FeatureDocs.markdown(), terminator: "")
    case .tools: print(ToolDocs.markdown(), terminator: "")
    }
  }
}
