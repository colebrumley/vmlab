import Foundation
import Testing

/// Constraint C3: Core is engine-free, and the MCP layer and CLI reach backends only through Core.
@Suite struct BoundariesTests {
  static let root = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  static let backendModules: Set = [
    "VMLabQEMU", "VMLabVZ", "VMLabRFB", "VMLabGDB", "Virtualization",
  ]

  /// Module names imported by a Swift source, including attributed and kind-qualified imports.
  static func imports(in source: String) -> Set<String> {
    let pattern =
      /^\s*(?:@\w+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)/
    var modules = Set<String>()
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      if let match = String(line).firstMatch(of: pattern) {
        modules.insert(String(match.1))
      }
    }
    return modules
  }

  /// Every import in every Swift file under `Sources/<target>`, keyed by relative path.
  static func importsByFile(target: String) throws -> [String: Set<String>] {
    let dir = root.appending(path: "Sources/\(target)")
    let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
    var result: [String: Set<String>] = [:]
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let source = try String(contentsOf: url, encoding: .utf8)
      result[url.path.replacingOccurrences(of: root.path + "/", with: "")] = imports(in: source)
    }
    return result
  }

  @Test func parserSeesEveryImportForm() {
    let source = """
      import Foundation
      @preconcurrency import Virtualization
      import struct MCP.Tool
      @_exported import VMLabGDB
      // import VMLabQEMU
      let x = "import VMLabRFB"
      """
    #expect(Self.imports(in: source) == ["Foundation", "Virtualization", "MCP", "VMLabGDB"])
  }

  @Test func coreImportsNoEngineOrMCP() throws {
    let forbidden = Self.backendModules.union(["MCP"])
    let files = try Self.importsByFile(target: "VMLabCore")
    #expect(!files.isEmpty)
    for (file, modules) in files {
      #expect(
        modules.isDisjoint(with: forbidden), "\(file) imports \(modules.intersection(forbidden))")
    }
  }

  @Test(arguments: ["VMLabMCP", "vmlab"])
  func adaptersImportNoBackend(target: String) throws {
    let files = try Self.importsByFile(target: target)
    #expect(!files.isEmpty)
    for (file, modules) in files {
      #expect(
        modules.isDisjoint(with: Self.backendModules),
        "\(file) imports \(modules.intersection(Self.backendModules))")
    }
  }

  /// `VMLabEngines` is the only module that names the engines: it imports exactly Core and the
  /// QEMU and VZ backends, and only the `vmlab` executable imports it.
  @Test func enginesModuleIsTheOnlyWiring() throws {
    let files = try Self.importsByFile(target: "VMLabEngines")
    #expect(!files.isEmpty)
    for (file, modules) in files {
      #expect(
        modules.isSubset(of: ["VMLabCore", "VMLabQEMU", "VMLabVZ"]), "\(file) imports \(modules)")
    }
    for target in ["VMLabCore", "VMLabMCP", "VMLabQEMU", "VMLabVZ"] {
      for (file, modules) in try Self.importsByFile(target: target) {
        #expect(!modules.contains("VMLabEngines"), "\(file) imports VMLabEngines")
      }
    }
  }

  /// The server-side VZ module never loads the framework; only the signed runner does.
  @Test func vzLibraryImportsNoVirtualization() throws {
    let files = try Self.importsByFile(target: "VMLabVZ")
    #expect(!files.isEmpty)
    for (file, modules) in files {
      #expect(!modules.contains("Virtualization"), "\(file) imports Virtualization")
    }
  }
}
