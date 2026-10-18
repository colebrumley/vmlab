import ArgumentParser
import Foundation
import VMLabCore
import VMLabMCP

/// The vmlab CLI. Phase 2 (R-2xx) adds the subcommands; `vmlab serve` runs the MCP server.
@main
struct VMLab: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vmlab",
    abstract: "Virtual machines for a language model, over MCP.",
    subcommands: [Images.self, GenDocs.self]
  )

  static func main() async {
    VMLabLogging.bootstrap()
    do {
      var command = try parseAsRoot()
      if var command = command as? AsyncParsableCommand {
        try await command.run()
      } else {
        try command.run()
      }
    } catch let error as VMLabError {
      // R-200 replaces this with the shared rendering; until then the Appendix D object as JSON.
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let text = (try? encoder.encode(error)).map { String(decoding: $0, as: UTF8.self) }
      FileHandle.standardError.write(Data(((text ?? error.message) + "\n").utf8))
      Foundation.exit(1)
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
