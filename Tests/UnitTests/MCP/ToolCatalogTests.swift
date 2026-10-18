import Foundation
import Testing
import VMLabCore

@testable import VMLabMCP

@Suite struct ToolCatalogTests {
  /// Appendix C, in order.
  static let appendixC = [
    "host_facts", "host_doctor", "images", "vm_plan", "vm_create", "vm_list", "vm_inspect",
    "vm_lifecycle", "vm_exec", "vm_job", "vm_file", "vm_computer", "vm_serial", "vm_debug",
    "vm_introspect", "vm_memory_dump", "vm_checkpoint", "vm_manifest", "vm_logs", "net_segment",
    "fleet",
  ]

  @Test func catalogueIsAppendixC() {
    #expect(ToolCatalog.all.map(\.name) == Self.appendixC)
    #expect(ToolCatalog.spec(named: "vm_exec")?.name == "vm_exec")
    #expect(ToolCatalog.spec(named: "nope") == nil)
  }

  @Test(arguments: ToolCatalog.all.map(\.name))
  func nameAndDescription(_ name: String) throws {
    let tool = try #require(ToolCatalog.spec(named: name))
    #expect(tool.name.wholeMatch(of: /[a-z0-9_]{1,40}/) != nil)
    #expect((40...1200).contains(tool.description.count), "\(tool.description.count) characters")
    for code in tool.errors { #expect(tool.description.contains(code.rawValue)) }
    #expect(!tool.outputShape.isEmpty)
  }

  @Test(arguments: ToolCatalog.all.map(\.name))
  func inputIsADraft2020_12ObjectSchema(_ name: String) throws {
    let tool = try #require(ToolCatalog.spec(named: name))
    guard case .object(let root) = tool.inputSchema else {
      Issue.record("input schema is not an object")
      return
    }
    #expect(root["$schema"] == .string("https://json-schema.org/draft/2020-12/schema"))
    #expect(root["type"] == .string("object"))
    #expect(Self.problems(tool.inputSchema, at: name) == [])
    // MCP clients take the schema as JSON; it must survive a round trip.
    let data = try JSONEncoder().encode(tool.inputSchema)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == tool.inputSchema)
  }

  @Test func actionToolsRequireTheirAction() throws {
    for tool in ToolCatalog.all {
      guard case .object(let root) = tool.inputSchema,
        case .object(let properties)? = root["properties"], properties["action"] != nil
      else { continue }
      guard case .array(let required)? = root["required"] else {
        Issue.record("\(tool.name) has no required list")
        continue
      }
      #expect(required.contains(.string("action")), "\(tool.name)")
    }
  }

  @Test func requirementsSchemaMatchesTheCoreType() throws {
    guard case .object(let node) = Schema.requirements,
      case .object(let properties)? = node["properties"]
    else {
      Issue.record("requirements is not an object schema")
      return
    }
    #expect(
      Set(properties.keys)
        == [
          "guest", "require", "prefer", "resources", "network", "image", "boot", "extra", "share",
        ])
    guard case .object(let require)? = properties["require"],
      case .object(let items)? = require["items"]
    else {
      Issue.record("require has no items")
      return
    }
    #expect(items["enum"] == .array(Feature.allCases.map { .string($0.rawValue) }))
    // The Appendix C example (minus fields Requirements does not have yet) decodes in Core.
    let example = """
      { "guest": { "os": "linux", "arch": "arm64" }, "require": ["serial", "gdb"],
        "prefer": ["net_fast"], "resources": { "cpus": 4, "memoryGB": 8, "diskGB": 32 },
        "network": { "mode": "nat", "forwards": [{ "guest": 22 }, { "guest": 8080, "host": 18080 }] },
        "image": "debian-13-arm64",
        "boot": { "mode": "kernel", "kernel": "k", "cmdline": "console=ttyAMA0", "haltAtStart": false } }
      """
    #expect(throws: Never.self) { try Requirements.decode(json: Data(example.utf8)) }
  }

  /// Structural checks of a JSON Schema node: a known `type`, `properties` an object of schemas,
  /// `required` a subset of `properties`, `enum` non-empty, unique and matching `type`, arrays
  /// with `items`, and bounds that are numbers.
  static func problems(_ schema: JSONValue, at path: String) -> [String] {
    guard case .object(let node) = schema else { return ["\(path): not an object"] }
    var out: [String] = []
    let types = ["object", "array", "string", "integer", "number", "boolean", "null"]
    guard case .string(let type)? = node["type"], types.contains(type) else {
      return ["\(path): missing or unknown type"]
    }
    if case .string(let text)? = node["description"], text.isEmpty {
      out.append("\(path): empty description")
    }
    if let values = node["enum"] {
      guard case .array(let items) = values, !items.isEmpty else {
        return out + ["\(path): enum is empty or not an array"]
      }
      if Set(items).count != items.count { out.append("\(path): enum has duplicates") }
      for item in items where type == "string" {
        if case .string = item {} else { out.append("\(path): enum value is not a string") }
      }
    }
    for key in ["minimum", "maximum", "minItems", "maxItems"] {
      if let value = node[key], case .number = value {
      } else if node[key] != nil {
        out.append("\(path): \(key) is not a number")
      }
    }
    switch type {
    case "object":
      guard case .object(let properties)? = node["properties"] else {
        return out + ["\(path): object without properties"]
      }
      if let required = node["required"] {
        guard case .array(let names) = required else {
          return out + ["\(path): required is not an array"]
        }
        for name in names {
          guard case .string(let key) = name, properties[key] != nil else {
            out.append("\(path): required \(name) is not a property")
            continue
          }
        }
      }
      for (key, property) in properties { out += problems(property, at: "\(path).\(key)") }
      if let extra = node["additionalProperties"], extra != .bool(false), extra != .bool(true) {
        out += problems(extra, at: "\(path).*")
      }
    case "array":
      guard let items = node["items"] else { return out + ["\(path): array without items"] }
      out += problems(items, at: "\(path)[]")
    default: break
    }
    return out
  }

  @Test func checkerCatchesBrokenSchemas() {
    let bad: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "a": .object(["type": .string("string"), "enum": .array([])]),
        "b": .object(["type": .string("array")]),
        "c": .object(["description": .string("no type")]),
      ]),
      "required": .array([.string("a"), .string("missing")]),
    ])
    let found = Self.problems(bad, at: "t")
    #expect(found.count == 4, "\(found)")
  }
}
