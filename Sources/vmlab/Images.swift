import ArgumentParser
import Foundation
import VMLabCore

/// `vmlab images pull|list|remove` over `ImageStore` (R-300). R-200 moves the handlers into the
/// shared MCP/CLI layer.
struct Images: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "images",
    abstract: "Pull, list and remove guest images.",
    subcommands: [Pull.self, List.self, Remove.self]
  )

  static func store() -> ImageStore { ImageStore(home: ImageStore.defaultHome()) }

  static func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
  }

  struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Download an image, verify its checksum and record it (a no-op when current).")

    @Argument(help: "The image name, from `vmlab images list`.") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func run() async throws {
      let store = Images.store()
      if !json { FileHandle.standardError.write(Data("Pulling \(name)...\n".utf8)) }
      let result = try await store.pull(name)
      if json { return try Images.printJSON(result) }
      let files = result.image.files.values.sorted().joined(separator: ", ")
      print(
        result.changed
          ? "Pulled \(name) into \(store.imageDirectory(name).path) (\(files))"
          : "\(name) is already pulled and current (\(files))")
    }
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show pulled and available images.")

    @Flag(help: "Print the rows as JSON.") var json = false

    func run() throws {
      let rows = Images.store().list()
      if json { return try Images.printJSON(rows) }
      for row in rows {
        let state = row.pulled.map { "pulled \($0.pulledAt.formatted(.iso8601))" } ?? "available"
        let name = row.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        let guest = "\(row.guest.os.rawValue)/\(row.guest.arch.rawValue)"
          .padding(toLength: 14, withPad: " ", startingAt: 0)
        print(
          "\(name)\(guest)\(row.format.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))\(state)"
        )
      }
    }
  }

  struct Removed: Encodable {
    var name: String
    var removed: Bool
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a pulled image.")

    @Argument(help: "The image name.") var name: String
    @Flag(help: "Print the result object as JSON.") var json = false

    func run() async throws {
      let removed = try await Images.store().remove(name)
      if json { return try Images.printJSON(Removed(name: name, removed: removed)) }
      print(removed ? "Removed \(name)" : "\(name) was not pulled")
    }
  }
}
