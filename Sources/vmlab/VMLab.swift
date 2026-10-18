import ArgumentParser
import Foundation
import VMLabCore
import VMLabEngines
import VMLabMCP

/// The vmlab CLI. Each tool subcommand (`ToolCommand`) calls the `VMLabMCP` handler of the tool
/// it mirrors; subcommands register here as their tools land. `vmlab serve` runs the MCP server.
@main
struct VMLab: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vmlab",
    abstract: "Virtual machines for a language model, over MCP.",
    version: VMLabMCP.version,
    subcommands: [
      FactsCommand.self, DoctorCommand.self, Images.self, PlanCommand.self, CreateCommand.self,
      ListCommand.self, InspectCommand.self, StartCommand.self, StopCommand.self,
      KillCommand.self, PauseCommand.self, ResumeCommand.self, ResetCommand.self,
      DestroyCommand.self, ExecCommand.self, JobCommand.self, LogsCommand.self,
      IntrospectCommand.self, MemoryDumpCommand.self, ManifestCommand.self, Serve.self,
      GenDocs.self,
    ]
  )

  static func main() async {
    VMLabLogging.bootstrap()
    // Every command, `serve` and the tool subcommands alike, reaches engines through `Backends`.
    Engines.registerAll(store: Store(home: Store.defaultHome()))
    Engines.registerProbes()
    do {
      var command = try parseAsRoot()
      if var command = command as? AsyncParsableCommand {
        try await command.run()
      } else {
        try command.run()
      }
    } catch let error as VMLabError {
      // A refusal: the Appendix D object with --json, otherwise code, message and hint.
      let json = CommandLine.arguments.dropFirst().contains("--json")
      let text = json ? ToolRendering.json(error) : ToolRendering.text(error)
      FileHandle.standardError.write(Data((text + "\n").utf8))
      Foundation.exit(1)
    } catch {
      exit(withError: error)
    }
  }
}

/// `vmlab serve`: the MCP server on stdin and stdout; logs go to stderr (`VMLAB_LOG` sets the
/// level). It reconciles the store first and stops when stdin closes.
struct Serve: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve", abstract: "Run the MCP server on stdin and stdout.")

  func run() async throws {
    try await VMLabServer.run(context: .live())
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

  func run() throws {
    switch document {
    case .features:
      // The last column is what this host's slow probes recorded (VMLAB_HOME, default ~/.vmlab).
      let environment = ProcessInfo.processInfo.environment
      let home =
        environment["VMLAB_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vmlab")
      let probes = try SlowProbes.load(from: SlowProbes.url(home: home))
      print(FeatureDocs.markdown(probes: probes), terminator: "")
    case .tools: print(ToolDocs.markdown(), terminator: "")
    }
  }
}
