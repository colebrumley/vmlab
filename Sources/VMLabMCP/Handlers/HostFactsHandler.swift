import VMLabCore

/// `host_facts`: the fast facts gathered now plus the persisted slow probes (Appendix E).
struct HostFactsHandler: ToolHandler {
  var spec: ToolSpec { .hostFacts }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let facts = try JSONValue(encoding: context.hostFacts())
    return ToolResult(facts.objectValue ?? [:])
  }
}
