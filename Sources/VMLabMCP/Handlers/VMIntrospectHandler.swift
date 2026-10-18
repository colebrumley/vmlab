import Foundation
import VMLabCore

/// `vm_introspect`: one read-only question to the engine about a running or paused VM, through
/// its `introspection` channel. `raw` takes exactly one of `qmp` or `hmp`; the engine refuses
/// anything outside its read-only allowlist.
struct VMIntrospectHandler: ToolHandler {
  var spec: ToolSpec { .vmIntrospect }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let name = try arguments.string("query") ?? ""
    let query = try Self.query(
      name, qmp: try arguments.string("qmp"), hmp: try arguments.string("hmp"))
    let vm = try await context.manager.attach(try arguments.string("vm") ?? "")
    let answer = try await vm.channel(.introspection).query(query)
    var result: [String: JSONValue] = ["query": .string(query.name)]
    switch answer {
    case .json(let value): result["json"] = value
    case .text(let text): result["text"] = .string(text)
    }
    return ToolResult(result)
  }

  static func query(_ name: String, qmp: String?, hmp: String?) throws(VMLabError)
    -> IntrospectionQuery
  {
    guard name == "raw" else {
      guard let query = IntrospectionQuery(name: name) else {
        throw VMLabError.invalidRequest(
          field: "query", reason: "\(name) is not a vm_introspect query",
          hint: "Use one of: \(IntrospectionQuery.names.joined(separator: ", ")).")
      }
      if qmp != nil || hmp != nil {
        throw VMLabError.invalidRequest(
          field: qmp != nil ? "qmp" : "hmp", reason: "qmp and hmp go with query raw only",
          hint: "Drop them, or set query to raw.")
      }
      return query
    }
    switch (qmp, hmp) {
    case (let command?, nil): return .qmp(command)
    case (nil, let command?): return .hmp(command)
    default:
      throw VMLabError.invalidRequest(
        field: "qmp", reason: "query raw takes exactly one of qmp or hmp",
        hint: "Pass qmp: \"query-chardev\" or hmp: \"info mtree\", not both.")
    }
  }
}
