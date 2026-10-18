import Foundation
import VMLabCore

/// `net_segment` (R-901): create starts the segment's switch with its own `10.n.0.0/24` subnet;
/// list shows every segment, its members and whether its switch runs; destroy stops the switch and
/// removes the segment once no VM is on it.
struct NetSegmentHandler: ToolHandler {
  var spec: ToolSpec { .netSegment }

  func call(_ arguments: ToolArguments, context: ToolContext) async throws(VMLabError)
    -> ToolResult
  {
    let segments = context.manager.segments
    switch try arguments.string("action") ?? "" {
    case "create":
      let name = try Self.name(arguments)
      let segment = try segments.create(name)
      do throws(VMLabError) {
        try await segments.startSwitch(name)
      } catch {
        try? await segments.destroy(name)
        throw error
      }
      return ToolResult(Self.object(segment, segments))
    case "list":
      return ToolResult([
        "segments": .array(segments.list().map { .object(Self.object($0, segments)) })
      ])
    case "destroy":
      let name = try Self.name(arguments)
      let segment = try segments.load(name)
      try await segments.destroy(name)
      var object = Self.object(segment, segments)
      object["running"] = .bool(false)
      object["destroyed"] = .bool(true)
      return ToolResult(object)
    case let action:
      throw VMLabError.invalidRequest(
        field: "action", reason: "\(action) is not a net_segment action",
        hint: "Use create, list or destroy.")
    }
  }

  static func object(_ segment: Segment, _ segments: SegmentStore) -> [String: JSONValue] {
    var object = segment.json.objectValue ?? [:]
    object["running"] = .bool(segments.switchPID(segment.name) != nil)
    return object
  }

  static func name(_ arguments: ToolArguments) throws(VMLabError) -> String {
    guard let name = try arguments.string("name"), !name.isEmpty else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "name is required for this action",
        hint: "Add the segment's name ([a-z0-9-], at most 32 characters).")
    }
    return name
  }
}
