import Testing
import VMLabCore

@testable import VMLabMCP

/// Every bound the server enforces on an argument is stated in that tool's input schema, from the
/// same constant the handler or Core checks against, so the model sees the limit before it calls.
@Suite struct ToolSchemaLimitsTests {
  /// (tool, path to the property, schema keyword, the constant the server enforces). A path
  /// segment `[]` steps into an array's `items`.
  static let bounds: [(tool: String, path: [String], key: String, value: Double)] = [
    // vm_computer: VMComputerHandler and DisplayRect.
    ("vm_computer", ["coordinate", "[]"], "minimum", 0),
    ("vm_computer", ["coordinate", "[]"], "maximum", Double(DisplayRect.coordinateLimit)),
    ("vm_computer", ["startCoordinate", "[]"], "maximum", Double(DisplayRect.coordinateLimit)),
    ("vm_computer", ["region", "[]"], "minimum", 0),
    ("vm_computer", ["region", "[]"], "maximum", Double(DisplayRect.coordinateLimit)),
    ("vm_computer", ["scrollAmount"], "minimum", 1),
    ("vm_computer", ["scrollAmount"], "maximum", Double(VMComputerHandler.maxScrollAmount)),
    ("vm_computer", ["durationSeconds"], "minimum", 0),
    ("vm_computer", ["durationSeconds"], "maximum", VMComputerHandler.maxWaitSeconds),
    ("vm_computer", ["settleMs"], "minimum", 0),
    ("vm_computer", ["settleMs"], "maximum", Double(VMComputerHandler.maxSettleMs)),
    ("vm_computer", ["settleMs"], "default", Double(VMComputerHandler.defaultSettleMs)),
    ("vm_computer", ["quality"], "minimum", Double(VMComputerHandler.qualityRange.lowerBound)),
    ("vm_computer", ["quality"], "maximum", Double(VMComputerHandler.qualityRange.upperBound)),
    ("vm_computer", ["quality"], "default", Double(ScreenshotRequest.defaultQuality)),
    ("vm_computer", ["maxEdge"], "minimum", 1),
    ("vm_computer", ["maxEdge"], "default", Double(ScreenshotRequest.defaultMaxEdge)),
    // vm_serial: VMSerialHandler and SerialChannel.
    ("vm_serial", ["since"], "minimum", 0),
    ("vm_serial", ["lines"], "maximum", Double(VMSerialHandler.maxTail)),
    ("vm_serial", ["timeoutSeconds"], "minimum", 1),
    ("vm_serial", ["timeoutSeconds"], "maximum", Double(VMSerialHandler.maxTimeoutSeconds)),
    ("vm_serial", ["pattern"], "maxLength", Double(SerialChannel.maxPatternBytes)),
    // vm_debug: VMDebugHandler.
    ("vm_debug", ["size"], "minimum", 1),
    ("vm_debug", ["size"], "maximum", Double(VMDebugHandler.maxBytes)),
    // vm_logs, vm_job, vm_exec: their handlers.
    ("vm_logs", ["tail"], "maximum", Double(VMLogsHandler.maxTail)),
    ("vm_logs", ["tail"], "default", Double(VMLogsHandler.defaultTail)),
    ("vm_job", ["timeoutSeconds"], "minimum", 1),
    ("vm_job", ["timeoutSeconds"], "default", Double(VMJobHandler.defaultWaitSeconds)),
    ("vm_exec", ["timeoutSeconds"], "minimum", 1),
    ("vm_exec", ["timeoutSeconds"], "default", Double(VMExecHandler.defaultTimeoutSeconds)),
    ("vm_memory_dump", ["size"], "minimum", 1),
    // fleet: FleetPlanning.
    ("fleet", ["count"], "minimum", 1),
    ("fleet", ["count"], "maximum", Double(FleetPlanning.maxMembers)),
    ("fleet", ["name"], "maxLength", Double(FleetPlanning.maxNameLength)),
    ("fleet", ["segment"], "maxLength", Double(SegmentStore.maxNameLength)),
    ("fleet", ["members"], "minItems", 1),
    ("fleet", ["members"], "maxItems", Double(FleetPlanning.maxMembers)),
    // Names: VMRecord.isValidName and SegmentStore.isValidName.
    ("vm_create", ["name"], "maxLength", Double(VMRecord.maxNameLength)),
    ("vm_lifecycle", ["name"], "maxLength", Double(VMRecord.maxNameLength)),
    ("vm_lifecycle", ["timeoutSeconds"], "minimum", 1),
    ("vm_checkpoint", ["name"], "maxLength", Double(VMRecord.maxNameLength)),
    ("net_segment", ["name"], "maxLength", Double(SegmentStore.maxNameLength)),
    // requirements (vm_plan, vm_create, fleet): Requirements.validate.
    ("vm_create", ["requirements", "resources", "cpus"], "maximum", Double(ResourceLimits.maxCPUs)),
    (
      "vm_create", ["requirements", "resources", "memoryGB"], "maximum",
      Double(ResourceLimits.maxMemoryGB)
    ),
    (
      "vm_create", ["requirements", "resources", "diskGB"], "maximum",
      Double(ResourceLimits.maxDiskGB)
    ),
    ("vm_create", ["requirements", "resources", "cpus"], "minimum", 1),
    ("vm_create", ["requirements", "network", "forwards", "[]", "guest"], "minimum", 1),
    ("vm_create", ["requirements", "network", "forwards", "[]", "host"], "maximum", 65535),
    (
      "vm_plan", ["requirements", "network", "segment"], "maxLength",
      Double(SegmentStore.maxNameLength)
    ),
    ("fleet", ["requirements", "resources", "cpus"], "maximum", Double(ResourceLimits.maxCPUs)),
  ]

  @Test(arguments: bounds.indices)
  func schemaStatesTheEnforcedBound(_ index: Int) throws {
    let (tool, path, key, value) = Self.bounds[index]
    let spec = try #require(ToolCatalog.spec(named: tool))
    let node = try #require(Self.property(spec.inputSchema, path), "\(tool) \(path)")
    #expect(node[key] == .number(value), "\(tool).\(path.joined(separator: ".")) \(key)")
  }

  /// The enums the handlers accept are the schemas' enums.
  @Test func actionEnumsMatchTheHandlers() throws {
    let cases: [(String, [String])] = [
      ("vm_computer", VMComputerHandler.actions), ("vm_debug", VMDebugHandler.actions),
    ]
    for (tool, actions) in cases {
      let spec = try #require(ToolCatalog.spec(named: tool))
      let node = try #require(Self.property(spec.inputSchema, ["action"]))
      #expect(node["enum"] == .array(actions.map { .string($0) }), "\(tool)")
    }
  }

  /// The limits a model cannot read off a keyword alone are in the description text.
  @Test func descriptionsStateTheLimits() {
    let computer = ToolSpec.vmComputer.description
    #expect(computer.contains("\(VMComputerHandler.maxSettleMs) ms"))
    #expect(computer.contains("\(DisplayRect.coordinateLimit)"))
    #expect(ToolSpec.vmMemoryDump.description.contains("\(VMMemoryDumpHandler.confirmAbove >> 20) MB"))
  }

  static func property(_ schema: JSONValue, _ path: [String]) -> [String: JSONValue]? {
    var node = schema.objectValue
    for step in path {
      if step == "[]" {
        node = node?["items"]?.objectValue
      } else {
        node = node?["properties"]?.objectValue?[step]?.objectValue
      }
    }
    return node
  }
}
