import Testing

@testable import VMLabMCP

@Suite struct ToolDocsTests {
  @Test func everyToolHasASection() {
    let doc = ToolDocs.markdown()
    for tool in ToolCatalog.all {
      #expect(doc.contains("\n## `\(tool.name)`\n"), "\(tool.name)")
      #expect(doc.contains(tool.outputShape), "\(tool.name)")
    }
    #expect(doc.contains("\n## Requirements\n"))
  }

  @Test func fieldsRenderWithTypesAndNesting() {
    let doc = ToolDocs.markdown()
    #expect(doc.contains("| `vm` | string | yes |"))
    #expect(doc.contains("| `requirements` | [requirements](#requirements) | yes |"))
    #expect(doc.contains("| `quality` | integer, 1–100, default `80` |"))
    #expect(doc.contains("| `format` | `png` \\| `jpeg`, default `png` |"))
    #expect(doc.contains("| `coordinate` | array of integer, ≥ 0 (2 items) |"))
    #expect(doc.contains("| `network.forwards[].guest` | integer, 1–65535 | yes |"))
    #expect(doc.contains("| `guest.os` | `macos` \\| `linux` | yes |"))
  }

  @Test func toolWithoutInputSaysNone() {
    #expect(ToolDocs.fieldTable(ToolSpec.hostFacts.inputSchema) == "None.\n")
  }
}
