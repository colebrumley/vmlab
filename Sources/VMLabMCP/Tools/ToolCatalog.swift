/// Every MCP tool of Appendix C, in the order `tools/list` and `docs/TOOLS.md` present them.
public enum ToolCatalog {
  public static let all: [ToolSpec] = [
    .hostFacts, .hostDoctor, .images, .vmPlan, .vmCreate, .vmList, .vmInspect, .vmLifecycle,
    .vmExec, .vmJob, .vmFile, .vmComputer, .vmSerial, .vmDebug, .vmIntrospect, .vmMemoryDump,
    .vmCheckpoint, .vmManifest, .vmLogs, .netSegment, .fleet,
  ]

  /// The tool called `name`, or nil.
  public static func spec(named name: String) -> ToolSpec? {
    all.first { $0.name == name }
  }
}
